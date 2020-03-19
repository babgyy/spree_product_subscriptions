module Spree
  class Subscription < Spree::Base

    attr_accessor :canceled

    include Spree::Core::NumberGenerator.new(prefix: 'S')

    ACTION_REPRESENTATIONS = {
                               pause: "Pause",
                               unpause: "Activate",
                               cancel: "Cancel"
                             }

    USER_DEFAULT_CANCELLATION_REASON = "Canceled By User"

    belongs_to :ship_address, class_name: "Spree::Address"
    belongs_to :bill_address, class_name: "Spree::Address"
    belongs_to :parent_order, class_name: "Spree::Order"
    belongs_to :variant, inverse_of: :subscriptions
    belongs_to :frequency, foreign_key: :subscription_frequency_id, class_name: "Spree::SubscriptionFrequency"
    belongs_to :source, polymorphic: true

    accepts_nested_attributes_for :ship_address, :bill_address

    has_many :orders_subscriptions, class_name: "Spree::OrderSubscription", dependent: :destroy
    has_many :orders, through: :orders_subscriptions
    has_many :complete_orders, -> { complete }, through: :orders_subscriptions, source: :order

    self.whitelisted_ransackable_associations = %w( parent_order )
    self.whitelisted_ransackable_attributes = %w( state )

    # scope :paused, -> { where(paused: true) }
    # scope :unpaused, -> { where(paused: false) }
    # scope :disabled, -> { where(enabled: false) }
    scope :awaiting_payment, -> { with_states(:pending, :paused)}
    
    scope :active, -> { with_states([:active_one_last_period, :active_and_renewable]) }
    scope :not_canceled, -> { where(canceled_at: nil) }
    # scope :with_appropriate_delivery_time, -> { where("next_occurrence_at <= :current_date", current_date: Time.current) }
    scope :processable, -> { unpaused.active.not_canceled }
    scope :eligible_for_subscription, -> { processable.with_appropriate_delivery_time }
    scope :with_parent_orders, -> (orders) { where(parent_order: orders) }

    with_options allow_blank: true do
      validates :price, numericality: { greater_than_or_equal_to: 0 }
      validates :quantity, numericality: { greater_than: 0, only_integer: true }
      validates :parent_order, uniqueness: { scope: :variant }
    end
    with_options presence: true do
      validates :quantity, :price, :number, :variant, :parent_order, :frequency
      validates :next_occurrence_at, :source, if: :active?
    end

    state_machine :state, initial: :pending do
      event :activate do
        transition pending: :active_and_renewable
      end
      after_transition on: :activate, do: :notify_start

      event :cancel do
        transition active_and_renewable: :active_one_last_period
        transition paused: :canceled
      end
      after_transition on: :cancel, do: :set_canceled_at!

      event :terminate do 
        transition active_one_last_period: :canceled
      end

      event :renew do 
        transition from: [:active_and_renewable, :paused], to: :processing
      end
      after_transition on: :renew, do: :process
        
      event :renew_success do
        transition processing: :active_and_renewable
      end
      after_transition on: :renew_success, do: :notify_renewal

      event :renew_failed do 
        transition processing: :paused
      end
      after_transition on: :renew_failed, do: [:set_paused_at!, :notify_failure]

      before_transition to: :active_and_renewable, do: [:set_activated_at!, :set_next_occurrence_at!]
      before_transition to: :active_one_last_period, do: [:set_activated_at!, :notify_last_period]
      after_transition from: [:active_and_renewable, :active_one_last_period], do: :record_active_duration!
      after_transition to: :canceled, do: :notify_cancellation
    end

    def set_next_occurrence_at!
      update(next_occurrence_at: next_occurrence_at_value)
    end

    def set_activated_at!
      update(activated_at: Time.zone.now)
    end

    def set_canceled_at!
      update(canceled_at: Time.zone.now)
    end

    def set_paused_at!
      update(paused_at: Time.zone.now)
    end

    def record_active_duration!
      update(active_duration_snapshot: active_duration)
    end

    def active? 
      active_one_last_period? or active_and_renewable?
    end

    def active_duration 
      if active? 
        active_duration_snapshot + (Time.zone.now - activated_at)
      else
        active_duration_snapshot
      end
    end

    def process
      # if (variant.stock_items.sum(:count_on_hand) >= quantity || variant.stock_items.any? { |stock| stock.backorderable? }) && (!variant.product.discontinued?)
      #   update_column(:next_occurrence_possible, true)
      # else
      #   update_column(:next_occurrence_possible, false)
      # end
      new_order = recreate_order if deliveries_remaining? # && next_occurrence_possible)
      if new_order && new_order.completed?
        # update(next_occurrence_at: next_occurrence_at_value)
        self.renew_success
      else 
        self.renew_failed
      end
    end

    def number_of_deliveries_left
      delivery_number.to_i - complete_orders.size - 1
    end

    def deliveries_remaining?
      number_of_deliveries_left > 0
    end

    private

      def next_occurrence_at_value
        deliveries_remaining? ? Time.current + frequency.months_count.month : nil
      end

      def recreate_order
        order = make_new_order
        add_variant_to_order(order)
        add_shipping_address(order)
        add_delivery_method_to_order(order)
        add_shipping_costs_to_order(order)
        add_payment_method_to_order(order)
        confirm_order(order)
        order
      end

      def make_new_order
        orders.create(order_attributes)
      end

      def add_variant_to_order(order)
        Spree::Dependencies.cart_add_item_service.constantize.call({
          order: order, 
          variant: variant, 
          quantity: quantity
        })
        order.next
      end

      def add_shipping_address(order)
        if order.address?
          order.ship_address = ship_address.clone
          order.bill_address = bill_address.clone
          order.next
        end
      end

      # select shipping method which was selected in original order.
      def add_delivery_method_to_order(order)
        if order.delivery?
          if !order.shipments.empty?
            selected_shipping_method_id = parent_order.shipments.first.shipping_method.id

            order.shipments.each do |shipment|
              current_shipping_rate = shipment.shipping_rates.find_by(selected: true)
              proposed_shipping_rate = shipment.shipping_rates.find_by(shipping_method_id: selected_shipping_method_id)

              if proposed_shipping_rate.present? && current_shipping_rate != proposed_shipping_rate
                current_shipping_rate.update(selected: false)
                proposed_shipping_rate.update(selected: true)
              end
            end
          end
          order.next
        end
      end

      def add_shipping_costs_to_order(order)
        order.set_shipments_cost
      end

      def add_payment_method_to_order(order)
        payment_method = source.is_a?(Spree::StoreCredit) ?
          Spree::PaymentMethod::StoreCredit.available.first : 
          source.payment_method
        if order.payments.exists?
          order.payments.first.update(source: source, payment_method: payment_method)
        else
          order.payments.create(source: source, payment_method: payment_method, amount: order.total)
        end
        order.next
      end

      def confirm_order(order)
        if order.confirm? 
          order.next
        end
      end

      def order_attributes
        {
          currency: parent_order.currency,
          token: parent_order.token,
          store: parent_order.store,
          user: parent_order.user,
          created_by: parent_order.user,
          last_ip_address: parent_order.last_ip_address
        }
      end

      def notify_start
        SubscriptionNotifier.notify_confirmation(self).deliver_later
      end

      def notify_cancellation
        SubscriptionNotifier.notify_cancellation(self).deliver_later
      end

      def notify_renewal
        SubscriptionNotifier.notify_reoccurrence(self).deliver_later
      end

      def notify_failure
        SubscriptionNotifier.notify_failure(self).deliver_later
      end

      def notify_last_period
        SubscriptionNotifier.notify_last_period(self).deliver_later
      end
  end
end
