require 'padrino-core/support_lite' unless defined?(SupportLite)
require 'padrino-core/path_router' unless defined?(PathRouter)

##
# Adds to Sinatra +controller+ informations
#
class Sinatra::Request
  attr_accessor :route_obj

  def controller
    route_obj && route_obj.controller
  end
  def action
    route_obj && route_obj.action
  end
end

module Padrino
  class Filter
    attr_reader :block

    def initialize(mode, scoped_controller, options, args, &block)
      @mode, @scoped_controller, @options, @args, @block = mode, scoped_controller, options, args, block
    end

    def apply?(request)
      detect = @args.any? do |arg|
        case arg
        when Symbol then request.route_obj && (request.route_obj.name == arg or request.route_obj.name == [@scoped_controller, arg].flatten.join("_").to_sym)
        else             arg === request.path_info
        end
      end || @options.any? do |name, val|
        case name
        when :agent then val === request.user_agent
        else             val === request.send(name)
        end
      end
      detect ^ !@mode
    end

    def to_proc
      if @args.empty? && @options.empty?
        block
      else
        filter = self
        proc { instance_eval(&filter.block) if filter.apply?(request) }
      end
    end
  end

  ##
  # Padrino provides advanced routing definition support to make routes and
  # url generation much easier. This routing system supports named route
  # aliases and easy access to url paths. The benefits of this is that instead
  # of having to hard-code route urls into every area of your application, now
  # we can just define the urls in a single spot and then attach an alias
  # which can be used to refer to the url throughout the application.
  #
  module Routing
    # Defines common content-type alias mappings.
    CONTENT_TYPE_ALIASES = { :htm => :html } unless defined?(CONTENT_TYPE_ALIASES)
    # Defines the available route priorities supporting route deferrals.
    ROUTE_PRIORITY = {:high => 0, :normal => 1, :low => 2} unless defined?(ROUTE_PRIORITY)

    # Raised when a route was invalid or cannot be processed.
    class UnrecognizedException < RuntimeError; end

    class Parent < String
      attr_reader :map
      attr_reader :optional
      attr_reader :options

      alias_method :optional?, :optional

      def initialize(value, options={})
        super(value.to_s)
        @map      = options.delete(:map)
        @optional = options.delete(:optional)
        @options  = options
      end
    end

    class << self
      ##
      # Main class that register this extension.
      #
      def registered(app)
        app.send(:include, InstanceMethods)
        app.extend(ClassMethods)
      end
      alias :included :registered
    end

    # Class methods responsible for enhanced routing for controllers.
    module ClassMethods
      ##
      # Method to organize our routes in a better way.
      #
      # @param [Array] args
      #   Controller arguments.
      #
      # @yield []
      #   The given block will be used to define the routes within the
      #   Controller.
      #
      # @example
      #   controller :admin do
      #     get :index do; ...; end
      #     get :show, :with => :id  do; ...; end
      #   end
      #
      #   url(:admin_index) # => "/admin"
      #   url(:admin_show, :id => 1) # "/admin/show/1"
      #
      # @example Using named routes follow the sinatra way:
      #   controller "/admin" do
      #     get "/index" do; ...; end
      #     get "/show/:id" do; ...; end
      #   end
      #
      # @example Supply +:provides+ to all controller routes:
      #   controller :provides => [:html, :xml, :json] do
      #     get :index do; "respond to html, xml and json"; end
      #     post :index do; "respond to html, xml and json"; end
      #     get :foo do; "respond to html, xml and json"; end
      #   end
      #
      # @example Specify parent resources in padrino with the +:parent+ option on the controller:
      #   controllers :product, :parent => :user do
      #     get :index do
      #       # url is generated as "/user/#{params[:user_id]}/product"
      #       # url_for(:product, :index, :user_id => 5) => "/user/5/product"
      #     end
      #     get :show, :with => :id do
      #       # url is generated as "/user/#{params[:user_id]}/product/show/#{params[:id]}"
      #       # url_for(:product, :show, :user_id => 5, :id => 10) => "/user/5/product/show/10"
      #     end
      #   end
      #
      # @example Specify conditions to run for all routes:
      #   controller :conditions => {:protect => true} do
      #     def self.protect(protected)
      #       condition do
      #         halt 403, "No secrets for you!" unless params[:key] == "s3cr3t"
      #       end if protected
      #     end
      #
      #     # This route will only return "secret stuff" if the user goes to
      #     # `/private?key=s3cr3t`.
      #     get("/private") { "secret stuff" }
      #
      #     # And this one, too!
      #     get("/also-private") { "secret stuff" }
      #
      #     # But you can override the conditions for each route as needed.
      #     # This route will be publicly accessible without providing the
      #     # secret key.
      #     get :index, :protect => false do
      #       "Welcome!"
      #     end
      #   end
      #
      # @example Supply default values:
      #   controller :lang => :de do
      #     get :index, :map => "/:lang" do; "params[:lang] == :de"; end
      #   end
      #
      # In a controller, before and after filters are scoped and don't
      #   affect other controllers or the main app.
      # In a controller, layouts are scoped and don't affect other
      #   controllers or the main app.
      #
      # @example
      #   controller :posts do
      #     layout :post
      #     before { foo }
      #     after  { bar }
      #   end
      #
      def controller(*args, &block)
        if block_given?
          options = args.extract_options!

          # Controller defaults.
          @_controller, original_controller = args,                        @_controller
          @_parents,    original_parent     = options.delete(:parent),     @_parents
          @_provides,   original_provides   = options.delete(:provides),   @_provides
          @_use_format, original_use_format = options.delete(:use_format), @_use_format
          @_cache,      original_cache      = options.delete(:cache),      @_cache
          @_map,        original_map        = options.delete(:map),        @_map
          @_conditions, original_conditions = options.delete(:conditions), @_conditions
          @_defaults,   original_defaults   = options,                     @_defaults

          # Application defaults.
          @filters,     original_filters    = { :before => @filters[:before].dup, :after => @filters[:after].dup }, @filters
          @layout,      original_layout     = nil, @layout

          instance_eval(&block)

          # Application defaults.
          @filters        = original_filters
          @layout         = original_layout

          # Controller defaults.
          @_controller, @_parents,  @_cache = original_controller, original_parent,   original_cache
          @_defaults,   @_provides, @_map   = original_defaults,   original_provides, original_map
          @_conditions, @_use_format        = original_conditions, original_use_format
        else
          include(*args) if extensions.any?
        end
      end
      alias :controllers :controller

      ##
      # Add a before filter hook.
      #
      # @see #construct_filter
      #
      def before(*args, &block)
        add_filter :before, &(args.empty? ? block : construct_filter(*args, &block))
      end

      ##
      # Add an after filter hook.
      #
      # @see #construct_filter
      #
      def after(*args, &block)
        add_filter :after, &(args.empty? ? block : construct_filter(*args, &block))
      end

      ##
      # Adds a filter hook to a request.
      #
      def add_filter(type, &block)
        filters[type] << block
      end

      ##
      # Creates a filter to process before/after the matching route.
      #
      # @param [Array] args
      #
      # @example We are be able to filter with String path
      #   before('/') { 'only to :index' }
      #   get(:index} { 'foo' } # => filter match only before this.
      #   get(:main) { 'bar' }
      #
      # @example is the same of
      #   before(:index) { 'only to :index' }
      #   get(:index} { 'foo' } # => filter match only before this.
      #   get(:main) { 'bar' }
      #
      # @example it works only for the given controller
      #   controller :foo do
      #     before(:index) { 'only to for :foo_index' }
      #     get(:index} { 'foo' } # => filter match only before this.
      #     get(:main) { 'bar' }
      #   end
      #
      #   controller :bar do
      #     before(:index) { 'only to for :bar_index' }
      #     get(:index} { 'foo' } # => filter match only before this.
      #     get(:main) { 'bar' }
      #   end
      #
      # @example if filters based on a symbol or regexp
      #   before :index, /main/ do; ... end
      #   # => match only path that are  +/+ or contains +main+
      #
      # @example filtering everything except an occurrence
      #   before :except => :index do; ...; end
      #
      # @example you can also filter using a request param
      #   before :agent => /IE/ do; ...; end
      #   # => match +HTTP_USER_AGENT+ containing +IE+
      #
      # @see http://www.padrinorb.com/guides/controllers#route-filters
      #
      def construct_filter(*args, &block)
        options = args.last.is_a?(Hash) ? args.pop : {}
        except = options.key?(:except) && Array(options.delete(:except))
        raise("You cannot use except with other options specified") if except && (!args.empty? || !options.empty?)
        options = except.last.is_a?(Hash) ? except.pop : {} if except
        Filter.new(!except, @_controller, options, Array(except || args), &block)
      end

      ##
      # Provides many parents with shallowing.
      #
      # @param [Symbol] name
      #   The parent name.
      #
      # @param [Hash] options
      #   Additional options.
      #
      # @example
      #   controllers :product do
      #     parent :shop, :optional => true, :map => "/my/stand"
      #     parent :category, :optional => true
      #     get :show, :with => :id do
      #       # generated urls:
      #       #   "/product/show/#{params[:id]}"
      #       #   "/my/stand/#{params[:shop_id]}/product/show/#{params[:id]}"
      #       #   "/my/stand/#{params[:shop_id]}/category/#{params[:category_id]}/product/show/#{params[:id]}"
      #       # url_for(:product, :show, :id => 10) => "/product/show/10"
      #       # url_for(:product, :show, :shop_id => 5, :id => 10) => "/my/stand/5/product/show/10"
      #       # url_for(:product, :show, :shop_id => 5, :category_id => 1, :id => 10) => "/my/stand/5/category/1/product/show/10"
      #     end
      #   end
      #
      def parent(name, options={})
        defaults = { :optional => false, :map => name.to_s }
        options = defaults.merge(options)
        @_parents = Array(@_parents) unless @_parents.is_a?(Array)
        @_parents << Parent.new(name, options)
      end

      ##
      # Using HttpRouter, for features and configurations.
      #
      # @example
      #   router.add('/greedy/:greed')
      #   router.recognize('/simple')
      #
      # @see http://github.com/joshbuddy/http_router
      #
      def router
        @router ||= PathRouter.new
        block_given? ? yield(@router) : @router
      end
      alias :urls :router

      def compiled_router
        if @deferred_routes
          deferred_routes.each { |routes| routes.each { |(route, dest)| route.to(&dest) } }
          @deferred_routes = nil
        end
        router
      end

      def deferred_routes
        @deferred_routes ||= ROUTE_PRIORITY.map{[]}
      end

      def reset_router!
        @deferred_routes = nil
        router.reset!
      end

      ##
      # Recognize a given path.
      #
      # @param [String] path
      #   Path+Query to parse
      #
      # @return [Symbol, Hash]
      #   Returns controller and query params.
      #
      # @example Giving a controller like:
      #   controller :foo do
      #     get :bar, :map => 'foo-bar-:id'; ...; end
      #   end
      #
      # @example You should be able to reverse:
      #   MyApp.url(:foo_bar, :id => :mine)
      #   # => /foo-bar-mine
      #
      # @example Into this:
      #   MyApp.recognize_path('foo-bar-mine')
      #   # => [:foo_bar, :id => :mine]
      #
      def recognize_path(path)
        responses = @router.recognize_path(path)
        [responses[0], responses[1]]
      end

      ##
      # Instance method for url generation.
      #
      # @example
      #   url(:show, :id => 1)
      #   url(:show, :name => 'test', :id => 24)
      #   url(:show, 1)
      #   url(:controller_name, :show, :id => 21)
      #   url(:controller_show, :id => 29)
      #
      def url(*args)
        params = args.extract_options!  # parameters is hash at end
        names, params_array = args.partition{|a| a.is_a?(Symbol)}
        name = names.join("_").to_sym    # route name is concatenated with underscores
        if params.is_a?(Hash)
          params[:format] = params[:format].to_s unless params[:format].nil?
          params = value_to_param(params)
        end
        url =
          if params_array.empty?
            compiled_router.path(name, params)
          else
            compiled_router.path(name, *(params_array << params))
          end
        url[0,0] = conform_uri(uri_root) if defined?(uri_root)
        url[0,0] = conform_uri(ENV['RACK_BASE_URI']) if ENV['RACK_BASE_URI']
        url = "/" if url.blank?
        url
      rescue PathRouter::InvalidRouteException
        route_error = "route mapping for url(#{name.inspect}) could not be found!"
        raise Padrino::Routing::UnrecognizedException.new(route_error)
      end
      alias :url_for :url

      def get(path, *args, &block)
        conditions = @conditions.dup
        route('GET', path, *args, &block)

        @conditions = conditions
        route('HEAD', path, *args, &block)
      end

      private
      # Parse params from the url method
      def value_to_param(value)
        case value
          when Array
            value.map { |v| value_to_param(v) }.compact
          when Hash
            value.inject({}) do |memo, (k,v)|
              v = value_to_param(v)
              memo[k] = v unless v.nil?
              memo
            end
          when nil then nil
          else value.respond_to?(:to_param) ? value.to_param : value
        end
      end

      # Add prefix slash if its not present and remove trailing slashes.
      def conform_uri(uri_string)
        uri_string.gsub(/^(?!\/)(.*)/, '/\1').gsub(/[\/]+$/, '')
      end

      ##
      # Rewrite default routes.
      #
      # @example
      #   get :index                                             # => "/"
      #   get :index, "/"                                        # => "/"
      #   get :index, :map => "/"                                # => "/"
      #   get :show, "/show-me"                                  # => "/show-me"
      #   get :show,  :map => "/show-me"                         # => "/show-me"
      #   get "/foo/bar"                                         # => "/show"
      #   get :index, :parent => :user                           # => "/user/:user_id/index"
      #   get :show, :with => :id, :parent => :user              # => "/user/:user_id/show/:id"
      #   get :show, :with => :id                                # => "/show/:id"
      #   get [:show, :id]                                       # => "/show/:id"
      #   get :show, :with => [:id, :name]                       # => "/show/:id/:name"
      #   get [:show, :id, :name]                                # => "/show/:id/:name"
      #   get :list, :provides => :js                            # => "/list.{:format,js)"
      #   get :list, :provides => :any                           # => "/list(.:format)"
      #   get :list, :provides => [:js, :json]                   # => "/list.{!format,js|json}"
      #   get :list, :provides => [:html, :js, :json]            # => "/list(.{!format,js|json})"
      #   get :list, :priority => :low                           # Defers route to be last
      #   get /pattern/, :name => :foo, :generate_with => '/foo' # Generates :foo as /foo
      def route(verb, path, *args, &block)
        options = case args.size
          when 2
            args.last.merge(:map => args.first)
          when 1
            map = args.shift if args.first.is_a?(String)
            if args.first.is_a?(Hash)
              map ? args.first.merge(:map => map) : args.first
            else
              {:map => map || args.first}
            end
          when 0
            {}
          else raise
        end

        route_options = options.dup
        route_options[:provides] = @_provides if @_provides

        if allow_disabled_csrf
          unless route_options[:csrf_protection] == false
            route_options[:csrf_protection] = true
          end
        end

        path, *route_options[:with] = path if path.is_a?(Array)
        action = path
        path, name, route_parents, options, route_options = *parse_route(path, route_options, verb)
        options.reverse_merge!(@_conditions) if @_conditions

        method_name = "#{verb} #{path}"
        unbound_method = generate_method(method_name, &block)

        block = block.arity != 0 ?
          proc {|a,p| unbound_method.bind(a).call(*p) } :
          proc {|a,p| unbound_method.bind(a).call }

        invoke_hook(:route_added, verb, path, block)

        path[0, 0] = "/" if path == "(.:format)"
        route = router.add(verb.downcase.to_sym, path, route_options)
        route.name = name if name
        route.action = action
        priority_name = options.delete(:priority) || :normal
        priority = ROUTE_PRIORITY[priority_name] or raise("Priority #{priority_name} not recognized, try #{ROUTE_PRIORITY.keys.join(', ')}")
        route.cache = options.key?(:cache) ? options.delete(:cache) : @_cache
        route.parent = route_parents ? (route_parents.count == 1 ? route_parents.first : route_parents) : route_parents
        route.host = options.delete(:host) if options.key?(:host)
        route.user_agent = options.delete(:agent) if options.key?(:agent)
        if options.key?(:default_values)
          defaults = options.delete(:default_values)
          route.default_values = defaults if defaults
        end
        options.delete_if do |option, captures|
          if route.significant_variable_names.include?(option)
            route.capture[option] = Array(captures).first
            true
          end
        end

        options.each {|o, a| route.respond_to?("#{o}=") ? route.send("#{o}=", a) : send(o, *a) }
        conditions, @conditions = @conditions, []
        route.custom_conditions.concat(conditions)

        invoke_hook(:padrino_route_added, route, verb, path, args, options, block)

        route.before_filters.concat(@filters[:before])
        route.after_filters.concat(@filters[:after])
        if @_controller
          route.use_layout = @layout
          route.controller = Array(@_controller)[0].to_s
        end

        deferred_routes[priority] << [route, block]

        route
      end

      ##
      # Returns the final parsed route details (modified to reflect all
      # Padrino options) given the raw route. Raw route passed in could be
      # a named alias or a string and is parsed to reflect provides formats,
      # controllers, parents, 'with' parameters, and other options.
      #
      def parse_route(path, options, verb)
        route_options = {}

        # We need check if path is a symbol, if that it's a named route.
        map = options.delete(:map)

        # path i.e :index or :show
        if path.kind_of?(Symbol)
          name = path
          path = map ? map.dup : (path == :index ? '/' : path.to_s)
        end

        # Build our controller
        controller = Array(@_controller).map(&:to_s)

        case path
        when String # path i.e "/index" or "/show"
          # Now we need to parse our 'with' params
          if with_params = options.delete(:with)
            path = process_path_for_with_params(path, with_params)
          end

          # Now we need to parse our provides
          options.delete(:provides) if options[:provides].nil?

          if @_use_format or format_params = options[:provides]
            process_path_for_provides(path, format_params)
            # options[:add_match_with] ||= {}
            # options[:add_match_with][:format] = /[^\.]+/
          end

          absolute_map = map && map[0] == ?/

          unless controller.empty?
            # Now we need to add our controller path only if not mapped directly
            if map.blank? and !absolute_map
              controller_path = controller.join("/")
              path.gsub!(%r{^\(/\)|/\?}, "")
              path = File.join(controller_path, path)  unless @_map
            end
          end

          # Now we need to parse our 'parent' params and parent scope.
          if !absolute_map and parent_params = options.delete(:parent) || @_parents
            parent_params = (Array(@_parents) + Array(parent_params)).uniq
            path = process_path_for_parent_params(path, parent_params)
          end

          # Add any controller level map to the front of the path.
          path = "#{@_map}/#{path}".squeeze('/') unless absolute_map or @_map.blank?

          # Small reformats
          path.gsub!(%r{/\?$}, '(/)')                  # Remove index path
          path.gsub!(%r{//$}, '/')                     # Remove index path
          path[0,0] = "/" if path !~ %r{^\(?/}         # Paths must start with a /
          path.sub!(%r{/(\))?$}, '\\1') if path != "/" # Remove latest trailing delimiter
          path.gsub!(/\/(\(\.|$)/, '\\1')              # Remove trailing slashes
          path.squeeze!('/')
        when Regexp
          route_options[:path_for_generation] = options.delete(:generate_with) if options.key?(:generate_with)
        end

        name = options.delete(:route_name) if name.nil? && options.key?(:route_name)
        name = options.delete(:name) if name.nil? && options.key?(:name)
        if name
          controller_name = controller.join("_")
          name = "#{controller_name}_#{name}".to_sym unless controller_name.blank?
        end

        # Merge in option defaults.
        options.reverse_merge!(:default_values => @_defaults)

        [path, name, parent_params, options, route_options]
      end

      ##
      # Processes the existing path and appends the 'with' parameters onto the route
      # Used for calculating path in route method.
      #
      def process_path_for_with_params(path, with_params)
        File.join(path, Array(with_params).map(&:inspect).join("/"))
      end

      ##
      # Processes the existing path and prepends the 'parent' parameters onto the route
      # Used for calculating path in route method.
      #
      def process_path_for_parent_params(path, parent_params)
        parent_prefix = parent_params.flatten.compact.uniq.map do |param|
          map  = (param.respond_to?(:map) && param.map ? param.map : param.to_s)
          part = "#{map}/:#{param.to_s.singularize}_id/"
          part = "(#{part})" if param.respond_to?(:optional) && param.optional?
          part
        end

        [parent_prefix, path].flatten.join("")
      end

      ##
      # Processes the existing path and appends the 'format' suffix onto the route.
      # Used for calculating path in route method.
      #
      def process_path_for_provides(path, format_params)
        path << "(.:format)" unless path[-10, 10] == '(.:format)'
      end

      ##
      # Allows routing by MIME-types specified in the URL or ACCEPT header.
      #
      # By default, if a non-provided mime-type is specified in a URL, the
      # route will not match an thus return a 404.
      #
      # Setting the :treat_format_as_accept option to true allows treating
      # missing mime types specified in the URL as if they were specified
      # in the ACCEPT header and thus return 406.
      #
      # If no type is specified, the first in the provides-list will be
      # returned.
      #
      # @example
      #   get "/a", :provides => [:html, :js]
      #   # => GET /a      => :html
      #   # => GET /a.js   => :js
      #   # => GET /a.xml  => 404
      #
      #   get "/b", :provides => [:html]
      #   # => GET /b; ACCEPT: html => html
      #   # => GET /b; ACCEPT: js   => 406
      #
      #   enable :treat_format_as_accept
      #   get "/c", :provides => [:html, :js]
      #   # => GET /c.xml => 406
      #
      def provides(*types)
        @_use_format = true
        condition do
          mime_types        = types.map { |t| mime_type(t) }.compact
          url_format        = params[:format].to_sym if params[:format]
          accepts           = request.accept.map(&:to_str)
          accepts           = [] if accepts == ["*/*"]

          # Per rfc2616-sec14:
          # Assume */* if no ACCEPT header is given.
          catch_all = (accepts.delete "*/*" || accepts.empty?)
          matching_types = accepts.empty? ? mime_types.slice(0,1) : (accepts & mime_types)
          if matching_types.empty? && types.include?(:any)
            matching_types = accepts
          end

          if !url_format && matching_types.first
            type = ::Rack::Mime::MIME_TYPES.find { |k, v| v == matching_types.first }[0].sub(/\./,'').to_sym
            accept_format = CONTENT_TYPE_ALIASES[type] || type
          elsif catch_all && !types.include?(:any)
            type = types.first
            accept_format = CONTENT_TYPE_ALIASES[type] || type
          end

          matched_format = types.include?(:any)            ||
                           types.include?(accept_format)   ||
                           types.include?(url_format)      ||
                           ((!url_format) && request.accept.empty? && types.include?(:html))

          # Per rfc2616-sec14:
          # Answer with 406 if accept is given but types to not match any
          # provided type.
          halt 406 if
            (!url_format && !accepts.empty? && !matched_format) ||
            (settings.respond_to?(:treat_format_as_accept) && settings.treat_format_as_accept && url_format && !matched_format)

          if matched_format
            @_content_type = url_format || accept_format || :html
            content_type(@_content_type, :charset => 'utf-8')
          end

          matched_format
        end
      end

      ##
      # Implements CSRF checking when `allow_disabled_csrf` is set to true.
      #
      # This condition is always on, except when it is explicitly switched
      # off.
      #
      # @example
      #   post("/", :csrf_protection => false)
      #
      def csrf_protection(on = true)
        if on
          condition { halt 403 if request.env['protection.csrf.failed'] }
        end
      end
    end

    ##
    # Instance methods related to recognizing and processing routes and serving static files.
    #
    module InstanceMethods
      ##
      # Instance method for URL generation.
      #
      # @example
      #   url(:show, :id => 1)
      #   url(:show, :name => :test)
      #   url(:show, 1)
      #   url("/foo")
      #
      # @see Padrino::Routing::ClassMethods#url
      #
      def url(*args)
        # Delegate to Sinatra 1.2 for simple url("/foo")
        # http://www.sinatrarb.com/intro#Generating%20URLs
        return super if args.first.is_a?(String) && !args[1].is_a?(Hash)

        # Delegate to Padrino named route URL generation.
        settings.url(*args)
      end
      alias :url_for :url

      ##
      # Returns absolute url. Calls Sinatra::Helpers#uri to generate protocol version, hostname and port.
      #
      # @example
      #   absolute_url(:show, :id => 1)  # => http://example.com/show?id=1
      #   absolute_url(:show, 24)        # => https://example.com/admin/show/24
      #
      def absolute_url( *args )
        uri url(*args), true, false
      end

      def recognize_path(path)
        settings.recognize_path(path)
      end

      ##
      # Returns the current path within a route from specified +path_params+.
      #
      def current_path(*path_params)
        if path_params.last.is_a?(Hash)
          path_params[-1] = params.merge(path_params[-1])
        else
          path_params << params
        end
        @route.path(*path_params)
      end

      ##
      # Returns the current route
      #
      # @example
      #   -if route.controller == :press
      #     %li=show_article
      #
      def route
        @route
      end

      ##
      # This is mostly just a helper so request.path_info isn't changed when
      # serving files from the public directory.
      #
      def static_file?(path_info)
        return if (public_dir = settings.public_folder).nil?
        public_dir = File.expand_path(public_dir)
        path = File.expand_path(public_dir + unescape(path_info))
        return if path[0, public_dir.length] != public_dir
        return unless File.file?(path)
        return path
      end

      #
      # Method for deliver static files.
      #
      def static!
        if path = static_file?(request.path_info)
          env['sinatra.static_file'] = path
          cache_control(*settings.static_cache_control) if settings.static_cache_control?
          send_file(path, :disposition => nil)
        end
      end

      ##
      # Return the request format, this is useful when we need to respond to
      # a given Content-Type.
      #
      # @param [Symbol, nil] type
      #
      # @param [Hash] params
      #
      # @example
      #   get :index, :provides => :any do
      #     case content_type
      #       when :js    then ...
      #       when :json  then ...
      #       when :html  then ...
      #     end
      #   end
      #
      def content_type(type=nil, params={})
        unless type.nil?
          super(type, params)
          @_content_type = type
        end
        @_content_type
      end

      private

      def filter!(type, base=settings)
        base.filters[type].each { |block| instance_eval(&block) }
      end

      def dispatch!
        invoke do
          static! if settings.static? && (request.get? || request.head?)
          route!
        end
      rescue ::Exception => boom
        filter! :before if boom.kind_of? ::Sinatra::NotFound
        invoke { @boom_handled = handle_exception!(boom) }
      ensure
        @boom_handled or begin
          filter! :after  unless env['sinatra.static_file']
        rescue ::Exception => boom
          invoke { handle_exception!(boom) } unless @env['sinatra.error']
        end
      end

      def route!(base = settings, pass_block = nil)
        Thread.current['padrino.instance'] = self
        code, headers, routes = begin
          base.compiled_router.call(@request.env)
        rescue PathRouter::NotFound, PathRouter::MethodNotAllowed
          $!.response
        end
        status(code)
        if code == 200
          routes.each_with_index do |(route, howl_params), index|
            next if route.user_agent && !(route.user_agent =~ @request.user_agent)
            invoke_route(route, howl_params, :first => index.zero?)
          end
        else
          route_eval do
            headers.each{|k, v| response[k] = v } unless headers.empty?
            route_missing if code == 404
            route_missing if allow = response['Allow'] and allow.include?(request.env['REQUEST_METHOD'])
          end
        end

        if base.superclass.respond_to?(:router)
          route!(base.superclass, pass_block)
          return
        end

        route_eval(&pass_block) if pass_block
        route_missing
      end

      def invoke_route(route, params, options = {})
        original_params, parent_layout, successful = @params.dup, @layout, false
        captured_params = params[:captures].is_a?(Array) ? params.delete(:captures) :
                                                           params.values_at(*route.matcher.names.dup)

        @_response_buffer = nil
        @route = request.route_obj = route
        @params.merge!(params) if params.is_a?(Hash)
        @params.merge!(:captures => captured_params) if !captured_params.empty? && route.path.is_a?(Regexp)
        @block_params = params

        filter! :before if options[:first]

        catch(:pass) do
          begin
            (route.before_filters - settings.filters[:before]).each{|block| instance_eval(&block) }
            @layout = route.use_layout if route.use_layout
            route.custom_conditions.each {|block| pass if block.bind(self).call == false }
            halt_response = catch(:halt){ route_eval{ route.block[self, captured_params] }}
            @_response_buffer = halt_response.is_a?(Array) ? halt_response.last : halt_response
            successful = true
            halt(halt_response)
          ensure
            (route.after_filters - settings.filters[:after]).each {|block| instance_eval(&block) } if successful
            @layout, @params = parent_layout, original_params
          end
        end
      end
    end
  end
end
