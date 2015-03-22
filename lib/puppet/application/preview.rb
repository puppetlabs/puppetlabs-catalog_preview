require 'puppet/application'
require 'puppet_x/puppetlabs/preview'

class Puppet::Application::Preview < Puppet::Application
  run_mode :master

  option("--debug", "-d")
  option("--verbose", "-v")

  # internal option, only to be used by ext/rack/config.ru
  option("--rack")

  option("--migrate host") do |arg|
    options[:node] = arg
  end

  option("--logdest DEST",  "-l DEST") do |arg|
    handle_logdest_arg(arg)
  end

  #option("--compile host",  "-c host") do |arg|
   #options[:node] = arg
  #end

  def help
    <<-'HELP'
USAGE
-----
puppet preview [-d|--debug] [-h|--help] [--migrate]
  [-l|--logdest syslog|<FILE>|console] [-v|--verbose] [-V|--version]
  [--compile <NODE-NAME>]

    HELP
  end

  # Sets up the 'node_cache_terminus' default to use the Write Only Yaml terminus :write_only_yaml.
  # If this is not wanted, the setting ´node_cache_terminus´ should be set to nil.
  # @see Puppet::Node::WriteOnlyYaml
  # @see #setup_node_cache
  # @see puppet issue 16753
  #
  def app_defaults
    super.merge({
      :node_cache_terminus => :write_only_yaml,
      :facts_terminus => 'yaml'
    })
  end

  def preinit
    Signal.trap(:INT) do
      $stderr.puts "Canceling startup"
      exit(0)
    end

    # save ARGV to protect us from it being smashed later by something
    @argv = ARGV.dup
  end

  def run_command
    if options[:node]
      checker = PuppetX::Puppetlabs::Migration::MigrationChecker.new
      Puppet.override({ :migration_checker => checker}, "migration-checking") do
        compile
        # Just dump messages to stdout for now...
        formatter = Puppet::Pops::Validation::DiagnosticFormatterPuppetStyle.new
        checker.acceptor.warnings.each { |w| puts "WARNING #{formatter.format(w)}" }
      end
    else
      main
    end
  end

  def compile
    begin
      # Wrap request to compile in a context specifying a migration checker
      #
      checker = PuppetX::Puppetlabs::Migration::MigrationChecker.new
      Puppet.override({ :migration_checker => checker}, "migration-checking") do

        # Do the compilation and get the catalog
        unless catalog = Puppet::Resource::Catalog.indirection.find(options[:node])
          raise "Could not compile catalog for #{options[:node]}"
        end

        # Output catalog to stdout
        puts PSON::pretty_generate(catalog.to_resource, :allow_nan => true, :max_nesting => false)

        # Outputs a bit of info (this is all just for temporary manual testing/viewing of results
        # Just dump messages to stdout for now...
        formatter = Puppet::Pops::Validation::DiagnosticFormatterPuppetStyle.new
        checker.acceptor.warnings.each { |w| puts "MIGRATION WARNING: #{formatter.format(w)}" }
      end
    rescue => detail
      Puppet.log_exception(detail, "Failed to compile catalog for node #{options[:node]}: #{detail}")
      exit(30)
    end
    exit(0)
  end

  def main
    require 'etc'
    # Make sure we've got a localhost ssl cert
    Puppet::SSL::Host.localhost

    # And now configure our server to *only* hit the CA for data, because that's
    # all it will have write access to.
    Puppet::SSL::Host.ca_location = :only if Puppet::SSL::CertificateAuthority.ca?

    if Puppet.features.root?
      begin
        Puppet::Util.chuser
      rescue => detail
        Puppet.log_exception(detail, "Could not change user to #{Puppet[:user]}: #{detail}")
        exit(39)
      end
    end

    if options[:rack]
      start_rack_master
    else
      start_webrick_master
    end
  end

  def setup_logs
    set_log_level

    if !options[:setdest]
      if options[:node]
        # We are compiling a catalog for a single node with '--compile' and logging
        # has not already been configured via '--logdest' so log to the console.
        Puppet::Util::Log.newdestination(:console)
      elsif !(Puppet[:daemonize] or options[:rack])
        # We are running a webrick master which has been explicitly foregrounded
        # and '--logdest' has not been passed, assume users want to see logging
        # and log to the console.
        Puppet::Util::Log.newdestination(:console)
      else
        # No explicit log destination has been given with '--logdest' and we're
        # either a daemonized webrick master or running under rack, log to syslog.
        Puppet::Util::Log.newdestination(:syslog)
      end
    end
  end

  def setup_terminuses
    require 'puppet/file_serving/content'
    require 'puppet/file_serving/metadata'

    Puppet::FileServing::Content.indirection.terminus_class = :file_server
    Puppet::FileServing::Metadata.indirection.terminus_class = :file_server

    Puppet::FileBucket::File.indirection.terminus_class = :file
  end

  def setup_ssl
    # Configure all of the SSL stuff.
    if Puppet::SSL::CertificateAuthority.ca?
      Puppet::SSL::Host.ca_location = :local
      Puppet.settings.use :ca
      Puppet::SSL::CertificateAuthority.instance
    else
      Puppet::SSL::Host.ca_location = :none
    end
    # These lines are not on stable (seems like a copy was made from master)
    #
    # Puppet::SSL::Oids.register_puppet_oids
    # Puppet::SSL::Oids.load_custom_oid_file(Puppet[:trusted_oid_mapping_file])
  end

  # Sets up a special node cache "write only yaml" that collects and stores node data in yaml
  # but never finds or reads anything (this since a real cache causes stale data to be served
  # in circumstances when the cache can not be cleared).
  # @see puppet issue 16753
  # @see Puppet::Node::WriteOnlyYaml
  # @return [void]
  def setup_node_cache
    Puppet::Node.indirection.cache_class = Puppet[:node_cache_terminus]
  end

  def setup
    raise Puppet::Error.new("Puppet master is not supported on Microsoft Windows") if Puppet.features.microsoft_windows?

    setup_logs

    exit(Puppet.settings.print_configs ? 0 : 1) if Puppet.settings.print_configs?

    Puppet.settings.use :main, :master, :ssl, :metrics

    setup_terminuses

    setup_node_cache

    setup_ssl
  end

  private

  # Start a master that will be using WeBrick.
  #
  # This method will block until the master exits.
  def start_webrick_master
    require 'puppet/network/server'
    daemon = Puppet::Daemon.new(Puppet::Util::Pidlock.new(Puppet[:pidfile]))

    daemon.argv = @argv
    daemon.server = Puppet::Network::Server.new(Puppet[:bindaddress], Puppet[:masterport])
    daemon.daemonize if Puppet[:daemonize]

    announce_start_of_master

    daemon.start
  end

  # Start a master that will be used for a Rack container.
  #
  # This method immediately returns the Rack handler that must be returned to
  # the calling Rack container
  def start_rack_master
    require 'puppet/network/http/rack'

    announce_start_of_master

    return Puppet::Network::HTTP::Rack.new()
  end

  def announce_start_of_master
    Puppet.notice "Starting Puppet master version #{Puppet.version}"
  end
end