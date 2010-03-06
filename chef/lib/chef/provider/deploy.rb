#
# Author:: Daniel DeLeo (<dan@kallistec.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef/mixin/command"
require "chef/mixin/from_file"
require "chef/provider/git"
require "chef/provider/subversion"

class Chef
  class Provider
    class Deploy < Chef::Provider
      
      include Chef::Mixin::FromFile
      include Chef::Mixin::Command
      
      attr_reader :scm_provider, :release_path, :previous_release_path
      
      def initialize(node, new_resource, collection=nil, definitions=nil, cookbook_loader=nil)
        super(node, new_resource, collection, definitions, cookbook_loader)
        
        # NOTE: workaround for CHEF-577
        @definitions ||= Hash.new
        @collection = Chef::ResourceCollection.new
        
        @scm_provider = @new_resource.scm_provider.new(@node, @new_resource)
        
        # @configuration is not used by Deploy, it is only for backwards compat with
        # chef-deploy or capistrano hooks that might use it to get environment information
        @configuration = @new_resource.to_hash
        @configuration[:environment] = @configuration[:environment] && @configuration[:environment]["RAILS_ENV"]
      end
      
      def load_current_resource
        @release_path = @new_resource.deploy_to + "/releases/#{release_slug}"
      end
      
      def sudo(command,&block)
        execute(command, &block)
      end
      
      def run(command, &block)
        exec = execute(command, &block)
        exec.user(@new_resource.user) if @new_resource.user
        exec.group(@new_resource.group) if @new_resource.group
        exec.cwd(release_path) unless exec.cwd
        exec.environment(@new_resource.environment) unless exec.environment 
        exec
      end
      
      def action_deploy
        save_release_state

        if deployed?(release_path)
          if current_release?(release_path) 
            Chef::Log.debug("Already deployed app at #{release_path}, and it is the latest revision.  Use action :force_deploy to re-deploy this revision.")
          else
            Chef::Log.info("Already deployed app at #{release_path}.  Rolling back to it - use action :force_deploy to re-checkout this revision.")
            action_rollback
          end
        else
          with_rollback_on_error do
            deploy
            @new_resource.updated = true
          end
        end
      end
      
      def action_force_deploy
        if deployed?(release_path)
          Chef::Log.info("Already deployed app at #{release_path}, forcing.")
          FileUtils.rm_rf(release_path)
        end

        # On error alternatives:
        # * Move release_path directory before deploy and move it back when error occurs
        # * Rollback to previous commit
        # * Do nothing - because deploy is force, it will be retried in short time
        # Because last is simpliest, keep it
        deploy
        @new_resource.updated = true
      end
      
      def action_rollback
        if release_path
          rp_index = all_releases.index(release_path)
          raise RuntimeError, "There is no release to rollback to!" unless rp_index
          rp_index += 1
          releases_to_nuke = all_releases[rp_index..-1]
        else
          @release_path = all_releases[-2] 
          raise RuntimeError, "There is no release to rollback to!" unless @release_path
          releases_to_nuke = [ all_releases.last ]
        end

        rollback

        releases_to_nuke.each do |i|
          Chef::Log.info "Removing release: #{i}"
          FileUtils.rm_rf i 
          release_deleted(i)
        end
        @new_resource.updated = true
      end
      
      def deploy
        Chef::Log.info "Start #{@new_resource}, branch: #{@new_resource.branch}"
        enforce_ownership
        update_cached_repo
        copy_cached_repo
        install_gems
        enforce_ownership
        callback(:before_migrate, @new_resource.before_migrate)
        migrate
        callback(:before_symlink, @new_resource.before_symlink)
        symlink
        callback(:before_restart, @new_resource.before_restart)
        restart
        callback(:after_restart, @new_resource.after_restart)
        cleanup!
      end

      def rollback
        Chef::Log.info "rolling back to previous release: #{release_path}"
        symlink
        Chef::Log.info "restarting with previous release"
        restart
      end

      def callback(what, callback_code=nil)
        @collection = Chef::ResourceCollection.new
        case callback_code
        when Proc
          Chef::Log.info "Running callback #{what} code block"
          recipe_eval(&callback_code)
        when String
          callback_file = "#{release_path}/#{callback_code}"
          unless ::File.exist?(callback_file)
            raise RuntimeError, "Can't find your callback file #{callback_file}"
          end
          run_callback_from_file(callback_file)
        when nil
          run_callback_from_file("#{release_path}/deploy/#{what}.rb")
        else
          raise RuntimeError, "You gave me a callback I don't know what to do with: #{callback_code.inspect}"
        end
      end
      
      def migrate
        run_symlinks_before_migrate
        
        if @new_resource.migrate
          enforce_ownership
          
          environment = @new_resource.environment
          env_info = environment && environment.map do |key_and_val| 
            "#{key_and_val.first}='#{key_and_val.last}'"
          end.join(" ")
          
          Chef::Log.info  "Migrating: running #{@new_resource.migration_command} as #{@new_resource.user} " +
                          "with environment #{env_info}"
          run_command(run_options(:command => @new_resource.migration_command, :cwd=>release_path))
        end
      end
      
      def symlink
        Chef::Log.info "Symlinking"
        purge_tempfiles_from_current_release
        link_tempfiles_to_current_release
        link_current_release_to_production
      end
      
      def restart
        if restart_cmd = @new_resource.restart_command
          if restart_cmd.kind_of?(Proc)
            Chef::Log.info("Restarting app with embedded recipe")
            recipe_eval(&restart_cmd)
          else
            Chef::Log.info("Restarting app with #{@new_resource.restart_command} in #{@new_resource.current_path}")
            run_command(run_options(:command => @new_resource.restart_command, :cwd => @new_resource.current_path))
          end
        end
      end
      
      def cleanup!
        all_releases[0..-6].each do |old_release|
          Chef::Log.info "Removing old release #{old_release}"
          FileUtils.rm_rf(old_release)
          release_deleted(old_release)
        end
      end
      
      def all_releases
        Dir.glob(@new_resource.deploy_to + "/releases/*").sort
      end
      
      def update_cached_repo
        if @new_resource.svn_force_export
          svn_force_export
        else
          run_scm_sync
        end
      end
      
      def run_scm_sync
        Chef::Log.info "updating the cached checkout"
        @scm_provider.action_sync
      end
      
      def svn_force_export
        Chef::Log.info "exporting source repository to #{@new_resource.destination}"
        @scm_provider.action_force_export
      end
      
      def copy_cached_repo
        Chef::Log.info "copying the cached checkout to #{release_path}"
        FileUtils.mkdir_p(@new_resource.deploy_to + "/releases")
        FileUtils.cp_r(::File.join(@new_resource.destination, "."), release_path, :preserve => true)
        release_created(release_path)
      end
      
      def enforce_ownership
        Chef::Log.info "ensuring proper ownership"
        FileUtils.chown_R(@new_resource.user, @new_resource.group, @new_resource.deploy_to)
      end
      
      def link_current_release_to_production
        Chef::Log.info "Linking release #{release_path} into production at #{@new_resource.current_path}"
        FileUtils.rm_f(@new_resource.current_path)
        FileUtils.ln_sf(release_path, @new_resource.current_path)
        enforce_ownership
      end
      
      def run_symlinks_before_migrate
        links_info = @new_resource.symlink_before_migrate.map { |src, dst| "#{src} => #{dst}" }.join(", ")
        Chef::Log.info "Making pre-migration symlinks: #{links_info}"
        @new_resource.symlink_before_migrate.each do |src, dest|
          FileUtils.ln_sf(@new_resource.shared_path + "/#{src}", release_path + "/#{dest}")
        end
      end
      
      def link_tempfiles_to_current_release
        dirs_info = @new_resource.create_dirs_before_symlink.join(",")
        Chef::Log.info("creating directories before symlink: #{dirs_info}")
        @new_resource.create_dirs_before_symlink.each { |dir| FileUtils.mkdir_p(release_path + "/#{dir}") }
        
        links_info = @new_resource.symlinks.map { |src, dst| "#{src} => #{dst}" }.join(", ")
        Chef::Log.info("Linking shared paths into current release: #{links_info}")
        @new_resource.symlinks.each do |src, dest|
          FileUtils.ln_sf(@new_resource.shared_path + "/#{src}",  release_path + "/#{dest}")
        end
        run_symlinks_before_migrate
        enforce_ownership
      end
      
      def create_dirs_before_symlink
      end
      
      def purge_tempfiles_from_current_release
        log_info = @new_resource.purge_before_symlink.join(", ")
        Chef::Log.info("Purging directories in checkout #{log_info}")
        @new_resource.purge_before_symlink.each { |dir| FileUtils.rm_rf(release_path + "/#{dir}") }
      end
      
      protected
      
      # Internal callback, called after copy_cached_repo.
      # Override if you need to keep state externally.
      def release_created(release_path)
      end
      
      # Internal callback, called during cleanup! for each old release removed.
      # Override if you need to keep state externally.
      def release_deleted(release_path)
      end
      
      def release_slug
        raise Chef::Exceptions::Override, "You must override release_slug in #{self.to_s}"
      end
      
      def install_gems
        gems_collection = Chef::ResourceCollection.new
        gem_packages.each { |rbgem| gems_collection << rbgem }
        Chef::Runner.new(@node, gems_collection).converge
      end
      
      def gem_packages
        return [] unless ::File.exist?("#{release_path}/gems.yml")
        gems = YAML.load(IO.read("#{release_path}/gems.yml"))
        
        gems.map do |g|
          r = Chef::Resource::GemPackage.new(g[:name], nil, node)
          r.version g[:version]
          r.action :install
          r.source "http://gems.github.com"
          r
        end
      end
      
      def run_options(run_opts={})
        run_opts[:user] = @new_resource.user if @new_resource.user
        run_opts[:group] = @new_resource.group if @new_resource.group
        run_opts[:environment] = @new_resource.environment if @new_resource.environment
        run_opts
      end
      
      def run_callback_from_file(callback_file)
        if ::File.exist?(callback_file)
          Dir.chdir(release_path) do
            Chef::Log.info "running deploy hook: #{callback_file}"
            recipe_eval { from_file(callback_file) }
          end
        end
      end

      def with_rollback_on_error
        yield
      rescue ::Exception => e
        Chef::Log.warn "Error on deploying #{release_path}: #{e.message}" 
        failed_release = release_path
        
        if previous_release_path
          @release_path = previous_release_path
          rollback
        end

        Chef::Log.info "Removing failed deploy #{failed_release}"
        FileUtils.rm_rf failed_release
        release_deleted(failed_release)
        
        raise
      end

      def save_release_state
        if ::File.exists?(@new_resource.current_path)
          release = ::File.readlink(@new_resource.current_path)
          @previous_release_path = release if ::File.exists?(release)
        end
      end

      def deployed?(release)
        all_releases.include?(release)
      end

      def current_release?(release)
        @previous_release_path == release
      end
    end
  end
end
