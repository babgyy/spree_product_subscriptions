FactoryBot.define do
  factory :monthly_subscription_frequency, class: Spree::SubscriptionFrequency do
    title { FFaker::Name.first_name }
    months_count { 1 }
  end
  factory :subscribable_product, parent: :product do 
    subscribable { true }

    after(:build) do |product| 
      product.subscription_frequencies = [build(:monthly_subscription_frequency)]
    end
  end

  factory :subscribable_variant, class: Spree::Variant, parent: :base_variant do 
    price { 19.9 }
    association :product, factory: :subscribable_product
  end

  factory :nil_attributes_subscription, class: Spree::Subscription do
  end

  factory :pending_subscription, class: Spree::Subscription do
    price { 20.00 }
    quantity { 2 } 
    delivery_number { 4 }
    association :variant, factory: :subscribable_variant 
    association :frequency, factory: :monthly_subscription_frequency
    association :parent_order, factory: :completed_order_with_totals
    association :ship_address, factory: :address
    association :bill_address, factory: :address
    association :source, factory: :credit_card

    factory :valid_subscription do
      state { :active_and_renewable } 
      next_occurrence_at { Time.zone.now + 10.days }
    end
  end

  factory :completed_order_with_captured_store_credit_payment, class: Spree::Order, parent: :completed_order_with_store_credit_payment do 
    state { :confirm }

    after(:create) do |order|
      create(:store_credit_payment, amount: (order.total * 10), order: order)
      order.next
    end
  end
end
