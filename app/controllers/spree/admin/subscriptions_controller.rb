module Spree
  module Admin
    class SubscriptionsController < Spree::Admin::ResourceController

      def cancellation
      end

      def cancel
        if @subscription.cancel_with_reason(permitted_cancel_subscription_attributes)
          flash[:success] = "Subscription is cancelled"
          redirect_to collection_url
        else
          flash[:error] = @subscription.errors.full_messages.join(", ")
          render :cancellation
        end
      end

      private

        def permitted_cancel_subscription_attributes
          params.require(:subscription).permit(:cancellation_reasons)
        end

        def collection
          @collection = super
          @search = @collection.ransack(params[:q])
          @collection = @search.result.active.order(created_at: :desc)
        end

    end
  end
end
