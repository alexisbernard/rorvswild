module RorVsWild
  class Client
    include RorVsWild::Location

    def self.default_config
      {
        api_url: "https://www.rorvswild.com/api",
        explain_sql_threshold: 500,
        ignored_exceptions: [],
      }
    end

    attr_reader :api_url, :api_key, :app_id, :explain_sql_threshold, :app_root, :ignored_exceptions

    attr_reader :threads, :app_root_regex

    def initialize(config)
      config = self.class.default_config.merge(config)
      @explain_sql_threshold = config[:explain_sql_threshold]
      @ignored_exceptions = config[:ignored_exceptions]
      @app_root = config[:app_root]
      @api_url = config[:api_url]
      @api_key = config[:api_key]
      @app_id = config[:app_id]
      @logger = config[:logger]
      @threads = Set.new
      @data = {}

      if defined?(Rails)
        @logger ||= Rails.logger
        @app_root ||= Rails.root.to_s
        config = Rails.application.config
        @parameter_filter = ActionDispatch::Http::ParameterFilter.new(config.filter_parameters)
        @ignored_exceptions ||= %w[ActionController::RoutingError] + config.action_dispatch.rescue_responses.map { |(key,value)| key }
      end

      @logger ||= Logger.new(STDERR)
      @app_root_regex = app_root ? /\A#{app_root}/ : nil

      setup_callbacks
      RorVsWild.register_client(self)
    end

    def setup_callbacks
      client = self
      if defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.subscribe("sql.active_record", &method(:after_sql_query))
        ActiveSupport::Notifications.subscribe("render_partial.action_view", &method(:after_view_rendering))
        ActiveSupport::Notifications.subscribe("render_template.action_view", &method(:after_view_rendering))
        ActiveSupport::Notifications.subscribe("process_action.action_controller", &method(:after_http_request))
        ActiveSupport::Notifications.subscribe("start_processing.action_controller", &method(:before_http_request))
        ActionController::Base.rescue_from(StandardError) { |exception| client.after_exception(exception, self) }
      end

      Plugin::Resque.setup
      Plugin::Sidekiq.setup
      Kernel.at_exit(&method(:at_exit))
      ActiveJob::Base.around_perform(&method(:around_active_job)) if defined?(ActiveJob::Base)
      Delayed::Worker.lifecycle.around(:invoke_job, &method(:around_delayed_job)) if defined?(Delayed::Worker)
    end

    def before_http_request(name, start, finish, id, payload)
      request.merge!(controller: payload[:controller], action: payload[:action], path: payload[:path], queries: [], views: {})
    end

    def after_http_request(name, start, finish, id, payload)
      request[:db_runtime] = (payload[:db_runtime] || 0).round
      request[:view_runtime] = (payload[:view_runtime] || 0).round
      request[:other_runtime] = compute_duration(start, finish) - request[:db_runtime] - request[:view_runtime]
      request[:error][:parameters] = filter_sensitive_data(payload[:params]) if request[:error]
      post_request
    rescue => exception
      log_error(exception)
    end

    IGNORED_QUERIES = %w[EXPLAIN SCHEMA].freeze

    def after_sql_query(name, start, finish, id, payload)
      return if !queries || IGNORED_QUERIES.include?(payload[:name])
      file, line, method = extract_most_relevant_location(caller)
      runtime, sql = compute_duration(start, finish), payload[:sql]
      plan = runtime >= explain_sql_threshold ? explain(payload[:sql], payload[:binds]) : nil
      push_query(file: file, line: line, method: method, sql: sql, plan: plan, runtime: runtime)
    rescue => exception
      log_error(exception)
    end

    def after_view_rendering(name, start, finish, id, payload)
      if views
        if view = views[file = relative_path(payload[:identifier])]
          view[:runtime] += compute_duration(start, finish)
          view[:times] += 1
        else
          views[file] = {file: file, runtime: compute_duration(start, finish), times: 1}
        end
      end
    end

    def after_exception(exception, controller)
      if !ignored_exception?(exception)
        file, line = exception.backtrace.first.split(":")
        request[:error] = exception_to_hash(exception).merge(
          session: controller.session.to_hash,
          environment_variables: filter_sensitive_data(filter_environment_variables(controller.request.env))
        )
      end
      raise exception
    end

    def around_active_job(job, block)
      measure_block(job.class.name, &block)
    end

    def around_delayed_job(job, &block)
      measure_block(job.name) { block.call(job) }
    end

    def measure_code(code)
      measure_block(code) { eval(code) }
    end

    def measure_block(name, &block)
      return block.call if job[:name] # Prevent from recursive jobs
      job[:name] = name
      job[:queries] = []
      started_at = Time.now
      cpu_time_offset = cpu_time
      begin
        block.call
      rescue Exception => ex
        job[:error] = exception_to_hash(ex) if !ignored_exception?(ex)
        raise
      ensure
        job[:runtime] = (Time.now - started_at) * 1000
        job[:cpu_runtime] = (cpu_time -  cpu_time_offset) * 1000
        post_job
      end
    end

    def catch_error(extra_details = nil, &block)
      begin
        block.call
      rescue Exception => ex
        record_error(ex, extra_details) if !ignored_exception?(ex)
        ex
      end
    end

    def record_error(exception, extra_details = nil)
      post_error(exception_to_hash(exception, extra_details))
    end

    def cpu_time
      time = Process.times
      time.utime + time.stime + time.cutime + time.cstime
    end

    #######################
    ### Private methods ###
    #######################

    private

    def queries
      data[:queries]
    end

    def views
      data[:views]
    end

    def job
      data
    end

    def request
      data
    end

    def data
      @data[Thread.current.object_id] ||= {}
    end

    def cleanup_data
      @data.delete(Thread.current.object_id)
    end

    MEANINGLESS_QUERIES = %w[BEGIN  COMMIT].freeze

    def push_query(query)
      hash = queries.find { |hash| hash[:line] == query[:line] && hash[:file] == query[:file] }
      queries << hash = {file: query[:file], line: query[:line], runtime: 0, times: 0} if !hash
      hash[:runtime] += query[:runtime]
      if !MEANINGLESS_QUERIES.include?(query[:sql])
        hash[:times] += 1
        hash[:sql] ||= query[:sql]
        hash[:plan] ||= query[:plan] if query[:plan]
      end
    end

    def slowest_views
      views.values.sort { |h1, h2| h2[:runtime] <=> h1[:runtime] }[0, 25]
    end

    def slowest_queries
      queries.sort { |h1, h2| h2[:runtime] <=> h1[:runtime] }[0, 25]
    end

    SELECT_REGEX = /\Aselect/i.freeze

    def explain(sql, binds)
      ActiveRecord::Base.connection.explain(sql, binds) if sql =~ SELECT_REGEX
    end

    def post_request
      attributes = request.merge(queries: slowest_queries, views: slowest_views)
      post_async("/requests".freeze, request: attributes)
    ensure
      cleanup_data
    end

    def post_job
      attributes = job.merge(queries: slowest_queries)
      post_async("/jobs".freeze, job: attributes)
    rescue => exception
      log_error(exception)
    ensure
      cleanup_data
    end

    def post_error(hash)
      post_async("/errors".freeze, error: hash)
    end

    def compute_duration(start, finish)
      ((finish - start) * 1000)
    end

    def exception_to_hash(exception, extra_details = nil)
      file, line, method = extract_most_relevant_location(exception.backtrace)
      {
        method: method,
        line: line.to_i,
        file: relative_path(file),
        message: exception.message,
        backtrace: exception.backtrace,
        exception: exception.class.to_s,
        extra_details: extra_details,
      }
    end

    HTTPS = "https".freeze
    CERTIFICATE_AUTHORITIES_PATH = File.expand_path("../../../cacert.pem", __FILE__)

    def post(path, data)
      uri = URI(api_url + path)
      http = Net::HTTP.new(uri.host, uri.port)

      if uri.scheme == HTTPS
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.ca_file = CERTIFICATE_AUTHORITIES_PATH
        http.use_ssl = true
      end

      post = Net::HTTP::Post.new(uri.path)
      post.content_type = "application/json".freeze
      post.basic_auth(app_id, api_key)
      post.body = data.to_json
      http.request(post)
    end

    def post_async(path, data)
      Thread.new do
        begin
          threads.add(Thread.current)
          post(path, data)
        ensure
          threads.delete(Thread.current)
        end
      end
    end

    def at_exit
      threads.each(&:join)
    end

    def filter_sensitive_data(hash)
      @parameter_filter ? @parameter_filter.filter(hash) : hash
    end

    def filter_environment_variables(hash)
      hash.clone.keep_if { |key,value| key == key.upcase }
    end

    def ignored_exception?(exception)
      ignored_exceptions.include?(exception.class.to_s)
    end

    def log_error(exception)
      @logger.error("[RorVsWild] " + exception.inspect)
      @logger.error("[RorVsWild] " + exception.backtrace.join("\n[RorVsWild] "))
    end
  end
end