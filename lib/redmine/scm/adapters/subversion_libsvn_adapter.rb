# Copyright (c) 2009 Pierre Paysant-Le Roux
 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

module Redmine::Scm::Adapters
  class SubversionLibsvnAdapter < AbstractAdapter
    
    KIND = { Svn::Core::NODE_NONE => "none",
      Svn::Core::NODE_DIR => "dir",
      Svn::Core::NODE_FILE => "file",
      Svn::Core::NODE_UNKNOWN => "unknown"}
    
    class << self        
      def client_version
        Svn::Core.subr_version.to_a[0..2]
      end
    end
    
    def target(path = '')
      base = path.match(/^\//) ? root_url : url
      # Remove leading slash else libsvn crash
      URI.escape(File.join(base, path).gsub(/\/\Z/,''))
    end
    
    def ctx
      if @ctx.nil?
        @ctx = Svn::Client::Context.new
        
        @ctx.add_simple_prompt_provider(1) do |cred, realm, username, may_save|
          cred.username = @login || ""
          cred.password = @password || ""
          cred.may_save = false
        end
        @ctx.add_username_prompt_provider(1) do |cred, realm, username, 
                                                 may_save|
          cred.username = @login || ""
          cred.may_save = false
        end
        @ctx.add_ssl_server_trust_prompt_provider do |cred, realm, failures, 
                                                      cert_info, may_save|
          cred.may_save = false
          if Setting.plugin_libsvn['trust_server_cert'].to_i > 0
            cred.accepted_failures = failures
          else
            errors = []
            if (failures & Svn::Core::AUTH_SSL_UNKNOWNCA > 0)
              errors << "the certificate is not issued by a trusted authority"
            end
            if (failures & Svn::Core::AUTH_SSL_CNMISMATCH > 0)
              errors << "the certificate hostname does not match"
            end
            if (failures & Svn::Core::AUTH_SSL_NOTYETVALID > 0)
              errors << "the certificate is not yet valid"
            end
            if (failures & Svn::Core::AUTH_SSL_EXPIRED > 0)
              errors << "the certificate has expired"
            end
            if (failures & Svn::Core::AUTH_SSL_OTHER > 0)
              errors << "the certificate has an unknown error"
            end
            raise Redmine::Scm::Adapters::CommandFailed, format("Invalid certificate for '%s': %s.", realm, errors.join(', '))
          end
          cred
        end
      end
      @ctx
    end
    
    # Get info about the svn repository
    def info
      ctx.info(target()) do |p,i|
        return Info.new({:root_url => i.repos_root_URL, #Nombre de slashs?
                          :lastrev => Revision.new({
                                                     :identifier => i.last_changed_rev.to_s,
                                                     :time => i.last_changed_date,
                                                     :author => i.last_changed_author
                                                   })
                        })            
      end
    end
    
    # Returns an Entries collection
    # or nil if the given path doesn't exist in the repository
    def entries(path=nil, identifier=nil)
      path ||= ''
      identifier = (identifier and identifier.to_i > 0) ? identifier.to_i : "HEAD"
      entries = Entries.new
      ctx.list(target(path), identifier) do |name,dirent,lock,abs_path| 
        entries.push(Entry.new({:name => name,
                                 :path => File.join(path,name).gsub(/\A\//,""), 
                                 :kind => KIND[dirent.kind],
                                 :size => dirent.size,
                                 :lastrev => 
                                 Revision.new({ :identifier => 
                                                dirent.created_rev.to_s,
                                                :time => dirent.time2,
                                                :author => 
                                                dirent.last_author
                                              })
                               })) unless name.blank?
        
      end
      logger.debug("Found #{entries.size} entries in the repository for #{target(path)}") if logger && logger.debug?
      entries.sort_by_name
    rescue Svn::Error::FsNotFound
      return nil
    end
    
    def properties(path, identifier=nil)
      identifier = (identifier and identifier.to_i > 0) ? identifier.to_i : "HEAD"
      properties = {}          
      ctx.proplist(target(path), identifier, identifier, 
                   Svn::Core::DEPTH_EMPTY) do |path, prop_hash|
        properties.merge!(prop_hash)
      end
      properties
    end
    
    def revisions(path=nil, identifier_from=nil, identifier_to=nil, options={})
      path ||= ''
      identifier_from = (identifier_from and identifier_from.to_i >= 0) ? identifier_from.to_i : "HEAD"
      identifier_to = (identifier_to and identifier_to.to_i >= 0) ? identifier_to.to_i : 0
      revisions = Revisions.new
      begin
        ctx.log(target(path), identifier_from, 
                identifier_to, options[:limit] || 0,
                options[:with_paths], 
                false, identifier_from) do |changed_paths, rev, author, date, message|
        
          paths = []
          changed_paths.each do |path, change|
            paths << {:action => change.action,
              :path => path,
              :from_path => change.copyfrom_path,
              :from_revision => change.copyfrom_rev
            }
          end unless changed_paths.nil?
        paths.sort! { |x,y| x[:path] <=> y[:path] }
        
          revisions << Revision.new({:identifier => rev.to_s,
                                      # identifier must be converted
                                      # to a string as
                                      # Changeset#revision is a string
                                    :author => author,
                                    :time => date,
                                    :message => message,
                                    :paths => paths
                                  })
      end
      rescue Svn::Error::ClientUnrelatedResources
      end
      revisions
    end
    
    
    def diff(path, identifier_from, identifier_to=nil, type="inline")
      path ||= ''
      identifier_from = (identifier_from and identifier_from.to_i > 0) ? identifier_from.to_i : ''
      identifier_to = (identifier_to and identifier_to.to_i > 0) ? identifier_to.to_i : (identifier_from.to_i - 1)
      begin
        out_file = Tempfile.new("redmine")
        err_file = Tempfile.new("redmine")
        ctx.diff_peg( [], target(path),
                      identifier_to,                                       
                      identifier_from, out_file.path, err_file.path, identifier_from)
        out_file.rewind
        diff = []
        out_file.each_line do |line|
          diff << line
        end
        return diff
      ensure
        out_file.unlink
        err_file.unlink
      end
    end
    
    def cat(path, identifier=nil)
      identifier = (identifier and identifier.to_i > 0) ? identifier.to_i : "HEAD"
      ctx.cat(target(path), identifier, identifier)
    end
    
    def annotate(path, identifier=nil)
      identifier = (identifier and identifier.to_i > 0) ? identifier.to_i : "HEAD"
      blame = Annotate.new
      ctx.blame(target(path), 
                nil, identifier) do |line_no, revision, author, date, line|
        blame.add_line(line, Revision.new(:identifier => revision.to_i, 
                                          :author => author,
                                          :time => date))
      end
      blame
    end
    
  end
  
end
