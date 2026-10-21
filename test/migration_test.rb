# frozen_string_literal: true

require 'minitest/autorun'
require 'erb'
require_relative '../lib/action_mailbox_graph'
require 'active_record/connection_adapters/abstract/schema_definitions'

class MigrationTest < Minitest::Test
  Schema = Struct.new(:adapter_name, :tables) do
    def supports_datetime_with_precision?
      true
    end

    def valid_column_definition_options
      ActiveRecord::ConnectionAdapters::ColumnDefinition::OPTION_NAMES
    end
  end

  def test_generated_mysql_schema_uses_binary_collation_for_both_opaque_id_keys
    %w[Mysql2 Trilogy].each do |adapter|
      tables = generated_schema(adapter)
      states = tables.fetch(:action_mailbox_graph_delta_states)
      receipts = tables.fetch(:action_mailbox_graph_receipts)

      assert_equal 'utf8mb4_bin', states[:folder].options[:collation]
      assert_equal 'utf8mb4_bin', receipts[:graph_message_id].options[:collation]
      assert_unique_index states, %w[mailbox folder]
      assert_unique_index receipts, %w[mailbox graph_message_id]
    end
  end

  def test_generated_postgresql_and_sqlite_schema_keeps_their_default_case_sensitive_id_columns
    %w[PostgreSQL SQLite].each do |adapter|
      tables = generated_schema(adapter)

      assert_nil tables.fetch(:action_mailbox_graph_delta_states)[:folder].options[:collation]
      assert_nil tables.fetch(:action_mailbox_graph_receipts)[:graph_message_id].options[:collation]
    end
  end

  private

  def generated_schema(adapter)
    template = File.expand_path('../lib/action_mailbox_graph/templates/create_action_mailbox_graph_tables.rb.erb', __dir__)
    output = ERB.new(File.read(template)).result
    scope = Module.new
    scope.module_eval(output, 'generated_migration.rb', 1)
    migration = scope.const_get(:CreateActionMailboxGraphTables).new
    schema = Schema.new(adapter, {})
    migration.define_singleton_method(:connection) { schema }
    migration.define_singleton_method(:create_table) do |name, &block|
      table = ActiveRecord::ConnectionAdapters::TableDefinition.new(schema, name)
      block.call(table)
      schema.tables[name] = table
    end
    migration.change
    schema.tables
  end

  def assert_unique_index(table, columns)
    index = table.indexes.find { |names, _options| Array(names).map(&:to_s) == columns }
    refute_nil index
    assert_equal true, index.last[:unique]
  end
end
