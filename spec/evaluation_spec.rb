# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "JsonSchemaValidator::Evaluation" do
  def evaluation_class
    JsonSchemaValidator.const_get(:Evaluation)
  end

  describe "#merge" do
    subject(:combined) { left.merge(right) }

    let(:left) { evaluation_class.valid(evaluated_properties: ["name"], evaluated_items: [0]) }

    context "with successful evaluations" do
      let(:right) { evaluation_class.valid(evaluated_properties: ["count"], evaluated_items: [1]) }

      it "combines evaluated properties and items", :aggregate_failures do
        expect(combined).to be_valid
        expect(combined.evaluated_properties).to contain_exactly("name", "count")
        expect(combined.evaluated_items).to contain_exactly(0, 1)
      end
    end

    context "with an unsuccessful evaluation" do
      let(:right) { evaluation_class.invalid }

      it "does not expose successful annotations", :aggregate_failures do
        expect(combined).not_to be_valid
        expect(combined.evaluated_properties).to be_empty
      end
    end
  end
end
