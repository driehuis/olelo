#!/usr/bin/env rackup
require 'wiki'

path = File.expand_path(File.dirname(__FILE__))
config_file = File.join(path, 'config.yml')
config = if File.exists?(config_file)
  YAML.load_file(config_file)
else
  { 'title'        => 'Git-Wiki',
    'repository'   => File.join(path, '.wiki', 'repository'),
    'workspace'    => File.join(path, '.wiki', 'workspace'),
    'store'        => File.join(path, '.wiki', 'store.yml'),
    'loglevel'     => 'INFO',
    'default_mime' => 'text/x-creole'
  }
end

Wiki::App.set :config, config
run Wiki::App

