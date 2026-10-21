# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'

class RailtieTest < Minitest::Test
  def test_initializer_selects_graph_after_lazy_registration_during_rails_boot
    script = <<~RUBY
      require 'rails'
      require 'action_mailer/railtie'
      require 'action_mailbox_graph'
      raise 'mailer loaded before application initializers' unless ActionMailer.autoload?(:Base)

      class GraphBootApplication < Rails::Application
        config.root = ARGV.fetch(0)
        config.eager_load = false
        config.secret_key_base = 'synthetic-boot-secret'
        config.logger = ActiveSupport::Logger.new(File::NULL)
        config.action_mailer.show_previews = false
      end

      GraphBootApplication.initialize!
      raise 'wrong transport selected' unless ActionMailer::Base.delivery_method == :microsoft_graph
      raise 'job arguments still logged' if ActionMailer::MailDeliveryJob.log_arguments
      unless ActionMailer::Base.delivery_methods[:microsoft_graph] == ActionMailboxGraph::DeliveryMethod
        raise 'Graph transport missing'
      end
      unless ActionMailer::Base.singleton_class.ancestors.include?(ActionMailboxGraph::DeliveryInstrumentation)
        raise 'Graph delivery instrumentation missing'
      end
      puts 'Graph selected after application initializers'
    RUBY
    fixture = File.expand_path('fixtures/boot_app', __dir__)
    library = File.expand_path('../lib', __dir__)

    output, error, status = Open3.capture3(RbConfig.ruby, "-I#{library}", '-e', script, fixture)

    assert status.success?, "#{output}\n#{error}"
    assert_includes output, 'Graph selected after application initializers'
  end
end
