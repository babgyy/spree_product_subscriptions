module Spree
  module V2
    module Storefront
      class SubscriptionFrequencySerializer < BaseSerializer
        
        set_type :subscription_frequency
        
        attributes :title, :months_count
      end
    end
  end
end
