module Spree
  module V2
    module Storefront
      class SubscriptionSerializer < BaseSerializer
        
        set_type :subscription
        
        attributes :enabled, :paused, :next_occurrence_at
        belongs_to :variant
      end
    end
  end
end
