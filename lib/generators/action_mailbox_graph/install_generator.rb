# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"

module ActionMailboxGraph
  class InstallGenerator < Rails::Generators::Base
    include Rails::Generators::Migration

    source_root File.expand_path("../../action_mailbox_graph/templates", __dir__)

    def copy_migration
      migration_template "create_action_mailbox_graph_tables.rb.erb", "db/migrate/create_action_mailbox_graph_tables.rb"
    end

    def self.next_migration_number(dirname)
      ActiveRecord::Generators::Base.next_migration_number(dirname)
    end
  end
end
