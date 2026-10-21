# frozen_string_literal: true

require 'rails'

module ActionMailboxGraph
  class Railtie < Rails::Railtie
    initializer 'action_mailbox_graph.configure' do |app|
      app.config.action_mailbox_graph ||= ActionMailboxGraph.configuration
      ActionMailboxGraph.configuration = app.config.action_mailbox_graph
    end

    rake_tasks do
      load File.expand_path('tasks/action_mailbox_graph.rake', __dir__)
    end

    generators do
      require 'generators/action_mailbox_graph/install_generator'
    end
  end
end
