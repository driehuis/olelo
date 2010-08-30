description 'Engine subsystem'
dependencies 'utils/cache'

# Engine context
# A engine context holds the request parameters and other
# variables used by the engines.
# It is possible for a engine to run sub-engines. For this
# purpose you create a subcontext which inherits the variables.
class Olelo::Context
  include Hooks

  attr_reader :page, :parent, :private, :params, :request, :response

  def initialize(attrs = {})
    @page     = attrs[:page]
    @parent   = attrs[:parent]
    @private  = attrs[:private]  || Hash.with_indifferent_access
    @params   = attrs[:params]   || Hash.with_indifferent_access
    @request  = attrs[:request]
    @response = attrs[:response] || Hash.with_indifferent_access
    invoke_hook(:initialized)
  end

  def subcontext(attrs = {})
    Context.new(:page     => attrs[:page] || @page,
                :parent   => self,
                :private  => @private.merge(attrs[:private] || {}),
                :params   => @params.merge(attrs[:params] || {}),
                :request  => @request,
                :response => @response)
  end
end

# An Engine renders pages
# Engines get a page as input and create text.
class Olelo::Engine
  include PageHelper
  include Templates

  @engines = {}

  class NotAvailable < NameError
    def initialize(name, page)
      super(:engine_not_available.t(:engine => name, :page => page.path,
                                    :type => "#{page.mime.comment} (#{page.mime})"))
    end
  end

  # Constructor for engine
  # Options:
  # * layout: Engine output should be wrapped in HTML layout (Not used for download/image engines for example)
  # * priority: Engine priority. The engine with the lowest priority will be used for a page.
  # * cacheable: Engine is cacheable
  def initialize(name, options)
    @name        = name.to_s
    @layout      = !!options[:layout]
    @hidden      = !!options[:hidden]
    @cacheable   = !!options[:cacheable]
    @priority    = (options[:priority] || 99).to_i
    @accepts     = options[:accepts]
    @mime        = options[:mime]
    @plugin      = options[:plugin] || Plugin.current(1)
    @description = options[:description] || @plugin.description
  end

  attr_reader :name, :priority, :mime, :accepts, :description, :plugin
  attr_reader? :layout, :hidden, :cacheable

  # Engines hash
  def self.engines
    @engines
  end

  # Create engine class. This is sugar to create and
  # register an engine class in one step.
  def self.create(name, options = {}, &block)
    klass = Class.new(Engine)
    klass.class_eval(&block)
    register klass.new(name, options)
  end

  # Register engine instance
  def self.register(engine)
    (@engines[engine.name] ||= []) << engine
  end

  # Find all accepting engines for a page which are not hidden
  def self.find_all(page)
    name = page.attributes['output']
    @engines.values.map do |engines|
      engines.sort_by {|e| e.priority }.find {|e| (e.name == name || !e.hidden?) && e.accepts?(page) }
    end.compact.sort_by {|e| e.name }
  end

  # Find appropiate engine for page. An optional
  # name can be given to claim a specific engine.
  # If no engine is found a exception is raised.
  def self.find!(page, options = {})
    options[:name] ||= page.attributes['output']
    engines = options[:name] ? @engines[options[:name].to_s] : @engines.values.flatten
    engine = engines.to_a.sort_by {|e| e.priority }.find { |e| e.accepts?(page) && (!options[:layout] || e.layout?) }
    raise NotAvailable.new(options[:name], page) if !engine
    engine.dup
  end

  # Find appropiate engine for page. An optional
  # name can be given to claim a specific engine.
  # If no engine is found nil is returned.
  def self.find(page, options = {})
    find!(page, options) rescue nil
  end

  # Acceptor should return true if page would be accepted by this engine.
  # Reimplement this method.
  def accepts?(page)
    page.mime.to_s =~ /#{@accepts}/
  end

  # Render page content.
  # Reimplement this method.
  def output(context); raise NotImplementedError; end
end

# Plug-in the engine subsystem
class Olelo::Application
  attribute_editor do
    attribute(:output) do
      Hash[*Engine.engines.keys.map do |name|
             [name, Olelo::I18n.translate("engine_#{name}", :fallback => name.tr('_', ' ').capitalize)]
           end.flatten]
    end
  end

  before :show do
    begin
      params[:output] ||= 'tree' if params[:path].to_s.ends_with? '/'
      @engine_name, layout, response, content =
        Cache.cache("engine-#{page.path}-#{page.version}-#{build_query(params)}",
                    :marshal => true, :update => request.no_cache?, :defer => true) do |cache|
        engine = Engine.find!(page, :name => params[:output])
        cache.disable! if !engine.cacheable?
        context = Context.new(:page => page, :params => params, :request => request)
        content = engine.output(context)
        context.response['Content-Type'] ||= engine.mime.to_s if engine.mime
        context.response['Content-Type'] ||= page.mime.to_s if !engine.layout?
        [engine.name, engine.layout?, context.response.to_hash, content]
      end
      self.response.header.merge!(response)
      if layout
        if request.xhr?
          content = "<h1>#{escape_html page.title}</h1>#{content}"
        else
          content = render(:show, :locals => {:content => content})
        end
      end
      halt content
    rescue Engine::NotAvailable => ex
      cache_control :no_cache => true
      redirect absolute_path(page) if params[:path].to_s.ends_with? '/'
      raise if params[:output]
      flash.error ex.message
      redirect action_path(page, :edit)
    end
  end

  hook :layout do |name, doc|
    doc.css('#menu .action-view').each do |link|
      menu = Cache.cache("engine-menu-#{page.path}-#{page.version}-#{build_query(params)}",
                         :update => request.no_cache?, :defer => true) do
        engines = Olelo::Engine.find_all(page)
        li = engines.select {|e| e.layout? }.map do |e|
          name = escape_html Olelo::I18n.translate("engine_#{e.name}", :fallback => e.name.tr('_', ' ').capitalize)
          %{<li#{e.name == @engine_name ? ' class="selected"': ''}>
          <a href="#{escape_html page_path(page, :output => e.name)}">#{name}</a></li>}.unindent
        end +
          engines.select {|e| !e.layout? }.map do |e|
          name = escape_html Olelo::I18n.translate("engine_#{e.name}", :fallback => e.name.tr('_', ' ').capitalize)
          %{<li class="download#{e.name == @engine_name ? 'selected': ''}">
                <a href="#{escape_html page_path(page, :output => e.name)}">#{name}</a></li>}.unindent
        end
        "<ul>#{li.join}</ul>"
      end
      link.after(menu)
    end
  end
end
