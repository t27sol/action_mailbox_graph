# frozen_string_literal: true

require 'action_mailbox_graph/version'
require 'active_record'
require 'action_mailbox'
require 'action_mailer'
require 'action_mailbox_graph/errors'
require 'action_mailbox_graph/configuration'
require 'action_mailbox_graph/token_provider'
require 'action_mailbox_graph/client'
require 'action_mailbox_graph/state_store'
require 'action_mailbox_graph/poller'
require 'action_mailbox_graph/delivery_method'

module ActionMailboxGraph
  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def poller
      Poller.new
    end
  end
end

require 'action_mailbox_graph/railtie' if defined?(Rails::Railtie)

ActionMailer::Base.add_delivery_method(:microsoft_graph, ActionMailboxGraph::DeliveryMethod)
