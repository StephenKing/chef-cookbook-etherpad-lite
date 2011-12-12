#
# Cookbook Name:: etherpad-lite
# Recipe:: default
#
# Copyright 2011, TYPO3 Association
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

# Create etherpad-lite User
user "etherpad-lite" do
  comment "etherpad-lite User"
  shell "/bin/bash"
end

packages = [
  'curl',
  'python',
  'libssl-dev'
]

case node[:platform]
when "debian", "ubuntu"
  packages.each do |pkg|
    package pkg do
      action :upgrade
  end
end
when "centos"
  log "No centos support yet"
end

##########
# Nodejs

# Download nodejs source code
remote_file "/usr/local/node-v#{node.etherpadlite.nodejs.version}.tar.gz" do
  source "http://nodejs.org/dist/v#{node.etherpadlite.nodejs.version}/node-v#{node.etherpadlite.nodejs.version}.tar.gz"
  mode "0644"
  action :create_if_missing
  notifies :run, "script[install_nodejs]"
end

# installation of nodejs bin
script "install_nodejs" do
  interpreter "bash"
  user "root"
  cwd "/usr/local"
  action :nothing
  code <<-EOH
  tar xfz node-v#{node.etherpadlite.nodejs.version}.tar.gz
  (cd node-v#{node.etherpadlite.nodejs.version} && ./configure)
  (cd node-v#{node.etherpadlite.nodejs.version} && make)
  (cd node-v#{node.etherpadlite.nodejs.version} && make install)
  EOH
end

#################
# etherpad-lite

# Create directories
directory "/var/log/etherpad-lite" do
  owner "etherpad-lite"
  group "etherpad-lite"
  mode "755"
end

directory "/usr/local/etherpad-lite" do
  owner "etherpad-lite"
  group "etherpad-lite"
  mode "755"
  notifies :run, "script[install_etherpad-lite]"
end

# installation of etherpad-lite
script "install_etherpad-lite" do
  interpreter "bash"
  user "etherpad-lite"
  code <<-EOH
  git clone "git://github.com/Pita/etherpad-lite.git" /usr/local/etherpad-lite
  EOH
  #action :nothing
  notifies :run, "script[install_dependencies]"
  notifies :start, "service[etherpad-lite]"
  not_if do
    File.exists?("/usr/local/etherpad-lite/README.md")
  end
end

script "install_dependencies" do
  interpreter "bash"
  user "root"
  cwd "/usr/local/etherpad-lite"
  action :nothing
  code <<-EOH
  bin/installDeps.sh
  chmod 755 /usr/local/lib/node*
  EOH
end


##################
# npmjs

execute "install_npmjs" do
  command "/tmp/install-npmjs.sh"
  action :nothing
end

remote_file "/tmp/install-npmjs.sh" do
  source "http://npmjs.org/install.sh"
  mode "0744"
  action :create_if_missing
  notifies :run, "execute[install_npmjs]"
end



############################
# etherpad-lite mysql setup

# Install MySQL server

include_recipe "mysql::server"
include_recipe "mysql::client"
include_recipe "database"

# generate the password
::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)
node.set_unless[:etherpadlite][:database][:password] = secure_password

mysql_connection_info = {:host => "localhost", :username => 'root', :password => node['mysql']['server_root_password']}


begin
  gem_package "mysql" do
    action :install
  end
  Gem.clear_paths  
  require 'mysql'
  m=Mysql.new("localhost","root",node['mysql']['server_root_password']) 

  if m.list_dbs.include?("etherpadlite") == false
    # create etherpad-lite database
    mysql_database 'etherpadlite' do
      connection mysql_connection_info
      action :create
      notifies :create, "template[/usr/local/etherpad-lite/settings.json]"
    end

    # create etherpad-lite user
    mysql_database_user 'etherpadlite' do
      connection mysql_connection_info
      password node[:etherpadlite][:database][:password]
      action :create
    end

    # Grant etherpad-lite
    mysql_database_user 'etherpadlite' do
      connection mysql_connection_info
      password node[:etherpadlite][:database][:password]
      database_name 'etherpadlite'
      host 'localhost'
      privileges [:select,:update,:insert,:create,:drop,:delete]
      action :grant
    end
  end
rescue LoadError
  Chef::Log.info("Missing gem 'mysql'")
end

template "/usr/local/etherpad-lite/settings.json" do
  source "settings.json.erb"
  owner "etherpad-lite"
  group "etherpad-lite"
  mode "644"
  notifies :restart, "service[etherpad-lite]"
end

# Install abiword package, if requested
if node[:etherpadlite][:settings][:abiword]
  package "abiword" do
      action :upgrade
  end
end


# Install Init script
template "/etc/init.d/etherpad-lite" do
  source "etherpad-lite.init.erb"
  owner "root"
  group "root"
  mode "754"
end

service "etherpad-lite" do
  supports :status => true, :start => true, :stop => true
  action [ :start, :enable ]
end

# nginx reverse proxy
if node[:etherpadlite][:proxy][:enable]
	include_recipe "nginx"
	
    template "/etc/nginx/sites-available/#{node.etherpadlite.proxy.hostname}" do
      source "nginx-site.erb"
      notifies :restart, "service[nginx]"
    end

    nginx_site "#{node.etherpadlite.proxy.hostname}" do
      enable true
    end

end