require 'dandelion/git'

module Dandelion
  module Deployment
    class RemoteRevisionError < StandardError; end
    class FastForwardError < StandardError; end
  
    class Deployment
      class << self
        def create(repo, backend, options)
          begin
            DiffDeployment.new(repo, backend, options)
          rescue RemoteRevisionError
            FullDeployment.new(repo, backend, options)
          end
        end
      end
      
      def initialize(repo, backend, options = {})
        @repo = repo
        @backend = backend
        @options = { :exclude => [], :additional => [], :revision => 'HEAD', :revision_file => '.revision' }.merge(options)
        @tree = Git::Tree.new(@repo, @options[:revision])
        
        if @options[:dry]
          # Stub out the destructive backend methods
          def @backend.write(file, data); end
          def @backend.delete(file); end
        end
      end
    
      def local_revision
        @tree.revision
      end
    
      def remote_revision
        nil
      end
    
      def write_revision
        @backend.write(@options[:revision_file], local_revision)
      end




      # Public: Determine if using a standard CMS and copy
      # the config file into the appropriate location.
      def write_production_config
        if @tree.files.include?("wp-config.prod.php")
          log.debug("Writing WordPress CMS config file.")
          @backend.write("wp-config.php", @tree.show("wp-config.prod.php"))
        end
        if @tree.files.include?("configuration.prod.php")
          log.debug("Writing Joomla CMS config file.")
          @backend.write("configuration.php", @tree.show("configuration.prod.php"))
        end
      end
      
      def validate
        begin
          raise FastForwardError if fast_forwardable
        rescue Grit::Git::CommandFailed
        end
      end
      
      def log
        Dandelion.logger
      end

      def deploy_additional
        self.write_production_config

        if @options[:additional].nil? || @options[:additional].empty?
          log.debug("No additional files to deploy")
          return
        end

        @options[:additional].each do |file|
          log.debug("Uploading additional file: #{file}")
          @backend.write(file, IO.read(file))
        end
      end
    
      protected
    
      def exclude_file?(file)
        @options[:exclude].map { |e| file.start_with?(e) }.any? unless @options[:exclude].nil?
      end
      
      private
      
      def fast_forwardable
        !@repo.git.native(:cherry, {:raise => true, :timeout => false}).empty?
      end
    end
  
    class DiffDeployment < Deployment
      def initialize(repo, backend, options = {})
        super(repo, backend, options)
        @diff = Git::Diff.new(@repo, read_remote_revision, @options[:revision])
      end
    
      def remote_revision
        @diff.from_revision
      end
    
      def deploy
        if !revisions_match? && any?
          prepare_host
          deploy_changed
          deploy_deleted
        else
          log.debug("No changes to deploy")
        end

        deploy_additional

        unless revisions_match?
          write_revision
        end
      end

      # Delete unneeded files provided by the hosting provider when partitioning
      # a new public html folder for a new user.
      def prepare_host
        log.debug "Deleting junk files created by hosting providers."
        junk_files = ["index.html", "gdform.php"]
        junk_files.each do |f|
          if !exclude_file?(f)
            #log.debug("Removing #{f} created by hosting provider.")
            @backend.delete_without_exception(f)
          end
        end
      end

      def deploy_changed
        @diff.changed.each do |file|
          if exclude_file?(file)
            log.debug("Skipping file: #{file}")
          else
            log.debug("Uploading file: #{file}")
            @backend.write(file, @tree.show(file))
          end
        end
      end
    
      def deploy_deleted
        @diff.deleted.each do |file|
          if exclude_file?(file)
            log.debug("Skipping file: #{file}")
          else
            log.debug("Deleting file: #{file}")
            @backend.delete(file)
          end
        end
      end
    
      def any?
        @diff.changed.any? || @diff.deleted.any?
      end
    
      def revisions_match?
        remote_revision == local_revision
      end
    
      private
    
      def read_remote_revision
        begin
          @backend.read(@options[:revision_file]).chomp
        rescue Backend::MissingFileError
          raise RemoteRevisionError
        end
      end
    end
  
    class FullDeployment < Deployment
      def deploy
        @tree.files.each do |file|
          if exclude_file?(file)
            log.debug("Skipping file: #{file}")
          else
            log.debug("Uploading file: #{file}")
            @backend.write(file, @tree.show(file))
          end
        end
        
        deploy_additional
        write_revision
      end
    end
  end
end
