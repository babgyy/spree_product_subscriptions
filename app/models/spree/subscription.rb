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

    # scope :paused, -> { where(paused: true) }
    # scope :unpaused, -> { where(paused: false) }
    # scope :disabled, -> { where(enabled: false) }
    scope :awaiting_payment, -> { with_states('pending', 'paused')}
    
    # scope :active, -> { where(enabled: true) }
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
        transition from: [:pending, :processing], to: :active
      end

      event :cancel do
        transition from: [:active, :paused], to: :canceled
      end

      event :renew do 
        transition from: [:active, :paused], to: :processing
      end

      event :failed do 
        transition from: :processing, to: :paused
      end

      after_transition from: :pending, to: :active, do: :notify_start
      after_transition from: :processing, to: :active, do: :notify_renewal
      after_transition to: :processing, do: :process
      before_transition to: :active, do: :set_activated_at_and_next_occurrence_at!
      after_transition from: :active, do: :record_active_duration!
      after_transition to: :canceled, do: [:set_canceled_at!, :notify_cancellation]
      after_transition to: :paused, do: [:set_paused_at!, :notify_failure]
    end

    # state_machine.states.each do 
    def set_activated_at_and_next_occurrence_at!
      update({
        activated_at: Time.zone.now,
        next_occurrence_at: next_occurrence_at_value
      })
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

    def active_duration 
      if active? 
        active_duration_snapshot + (Time.zone.now - activated_at)
      else
        active_duration_snapshot
      end
    end

    def process
      if (variant.stock_items.sum(:count_on_hand) >= quantity || variant.stock_items.any? { |stock| stock.backorderable? }) && (!variant.product.discontinued?)
        update_column(:next_occurrence_possible, true)
      else
        update_column(:next_occurrence_possible, false)
      end
      new_order = recreate_order if (deliveries_remaining? && next_occurrence_possible)
      update(next_occurrence_at: next_occurrence_at_value) if new_order.try :completed?
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
        order.contents.add(variant, quantity)
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
            selected_shipping_method_id = parent_order.inventory_units.where(variant_id: variant.id).first.shipment.shipping_method.id

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
        if order.payments.exists?
          order.payments.first.update(source: source, payment_method: source.payment_method)
        else
          order.payments.create(source: source, payment_method: source.payment_method, amount: order.total)
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
          guest_token: parent_order.guest_token,
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
  end
end
