# frozen_string_literal: true

# Single-file Rails app demonstrating the PROPOSED FIX for the includes issue
# This file patches LoaderQuery#eql? and #hash to include klass in comparison
# Run with: ruby rails_bug_proposed_fix.rb

require 'bundler/inline'
require 'logger' # Required for Rails < 7.1 compatibility with Ruby 3.2+

rails_version = ENV['RAILS_VERSION'] || '7.1'

gemfile(true) do
  source 'https://rubygems.org'
  gem 'rails', rails_version

  # Use compatible sqlite3 version based on Rails version
  if rails_version < '7.1'
    gem 'sqlite3', '~> 1.4'
  else
    gem 'sqlite3'
  end
end

require 'active_record'

# Connect to in-memory SQLite database
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

ActiveRecord::Base.logger = Logger.new($stdout)

# Create the schema
ActiveRecord::Schema.define do
  create_table :custom_fields, force: true do |t|
    t.string :name
    t.integer :origin_field_id
    t.boolean :survey
    t.timestamps
  end

  create_table :custom_field_options, force: true do |t|
    t.integer :custom_field_id
    t.integer :creator_id
    t.string :value
    t.timestamps
  end

  create_table :people, force: true do |t|
    t.string :name
    t.timestamps
  end
end

# Define the models
class SurveyField < ActiveRecord::Base
  self.table_name = 'custom_fields'
  has_many :options, foreign_key: :custom_field_id, class_name: 'SurveyFieldOption', dependent: :destroy
  belongs_to :origin_field, class_name: 'CustomField', optional: true
end

class SurveyFieldOption < ActiveRecord::Base
  self.table_name = 'custom_field_options'
  belongs_to :survey_field, foreign_key: :custom_field_id, class_name: 'SurveyField', touch: true
  belongs_to :creator, class_name: 'Person'
end

class CustomField < ActiveRecord::Base
  self.table_name = 'custom_fields'
  has_many :options, class_name: 'CustomFieldOption', dependent: :destroy
end

class CustomFieldOption < ActiveRecord::Base
  self.table_name = 'custom_field_options'
  belongs_to :custom_field, class_name: 'CustomField', foreign_key: :custom_field_id
  belongs_to :creator, class_name: 'Person'
end

class Person < ActiveRecord::Base
  self.table_name = 'people'
end

# ============================================================================
# PROPOSED FIX: Patch LoaderQuery to include klass in eql? and hash methods
# ============================================================================
module LoaderQueryClassFix
  def eql?(other)
    # Original comparison:
    # association_key_name == other.association_key_name &&
    #   scope.table_name == other.scope.table_name &&
    #   scope.connection_specification_name == other.scope.connection_specification_name &&
    #   scope.values_for_queries == other.scope.values_for_queries

    # FIXED: Added scope.klass comparison
    association_key_name == other.association_key_name &&
      scope.table_name == other.scope.table_name &&
      scope.klass == other.scope.klass && # FIX: Include klass in comparison
      scope.connection_specification_name == other.scope.connection_specification_name &&
      scope.values_for_queries == other.scope.values_for_queries
  end

  def hash
    # Original hash:
    # [association_key_name, scope.table_name, scope.connection_specification_name, scope.values_for_queries].hash

    # FIXED: Added scope.klass to hash
    [
      association_key_name,
      scope.table_name,
      scope.klass, # FIX: Include klass in hash
      scope.connection_specification_name,
      scope.values_for_queries
    ].hash
  end
end

# Apply the patch
ActiveRecord::Associations::Preloader::Association::LoaderQuery.prepend(LoaderQueryClassFix)

puts "\n#{'=' * 80}"
puts '🔧 PROPOSED FIX APPLIED'
puts '=' * 80
puts 'Patched LoaderQuery#eql? and #hash to include scope.klass in comparison'
puts 'This ensures loaders with different target classes are not batched together'
puts '=' * 80

# ============================================================================
# PATCH: Add debug logging to verify the fix works
# ============================================================================
module DebugPreloaderPatch
  def associate_records_to_owner(owner, records)
    mismatch = records.any? { |r| r.class.name != reflection.class_name }
    prefix = mismatch ? '❌' : '✅'

    puts "\n#{prefix} DEBUG: Associate #{records.size} records to owner"
    puts "   Owner: #{owner.class.name}##{owner.id}"
    puts "   Reflection: #{reflection.name} -> #{reflection.class_name}"
    puts "   Records: #{records.map { |r| "#{r.class.name}##{r.id}" }.join(', ')}"
    puts "   ⚠️  CLASS MISMATCH! Expected #{reflection.class_name}, got #{records.first.class.name}" if mismatch

    super
  end

  def build_records(rows)
    puts "\n🏗️  DEBUG: Building #{rows.size} records"
    puts "   Reflection: #{reflection.name} -> #{reflection.class_name}"
    puts "   Klass: #{klass.name}"
    puts "   Rows: #{rows.map { |r| "id=#{r['id']}, custom_field_id=#{r['custom_field_id']}" }.join('; ')}"

    records = super

    puts "   Built: #{records.map { |r| "#{r.class.name}##{r.id}" }.join(', ')}"

    records
  end
end

ActiveRecord::Associations::Preloader::Association.prepend(DebugPreloaderPatch)

# Create test data
puts "\n=== Creating test data ===\n"

person1 = Person.create!(name: 'Alice')
person2 = Person.create!(name: 'Bob')

origin_field = CustomField.create!(name: 'Origin Field')
CustomFieldOption.create!(custom_field: origin_field, creator: person1, value: 'Option 1')
CustomFieldOption.create!(custom_field: origin_field, creator: person2, value: 'Option 2')

survey_field = SurveyField.create!(name: 'Survey Field', origin_field: origin_field, survey: true)
SurveyFieldOption.create!(survey_field: survey_field, creator: person1, value: 'Survey Option 1')
SurveyFieldOption.create!(survey_field: survey_field, creator: person2, value: 'Survey Option 2')

def execute(result, test_name)
  puts "\n=== Output ===\n"

  all_correct = true

  result.each do |record|
    puts "Record: id=#{record.id}, name='#{record.name}', class=#{record.class}"

    # Show options
    record.options.each do |option|
      expected_class = record.is_a?(SurveyField) ? SurveyFieldOption : CustomFieldOption
      is_correct = option.instance_of?(expected_class)
      marker = is_correct ? '✅' : '❌'
      all_correct = false unless is_correct
      puts "  #{marker} Option: id=#{option.id}, value='#{option.value}', class=#{option.class} (expected: #{expected_class})"
    end

    # Show origin_field if exists
    if record.respond_to?(:origin_field) && record.origin_field
      puts "  OriginField: id=#{record.origin_field.id}, name='#{record.origin_field.name}', class=#{record.origin_field.class}"

      # Show origin_field options
      record.origin_field.options.each do |option|
        expected_class = CustomFieldOption
        is_correct = option.instance_of?(expected_class)
        marker = is_correct ? '✅' : '❌'
        all_correct = false unless is_correct
        puts "    #{marker} OriginOption: id=#{option.id}, value='#{option.value}', class=#{option.class} (expected: #{expected_class})"
      end
    end
    puts ''
  end

  puts "\n#{'=' * 80}"
  if all_correct
    puts "✅ #{test_name}: PASSED - All classes are correct!"
  else
    puts "❌ #{test_name}: FAILED - Some classes are incorrect!"
  end
  puts '=' * 80

  all_correct
rescue StandardError => e
  puts "\nERROR!"
  puts "Exception: #{e.class}"
  puts "Message: #{e.message}"
  puts "\nBacktrace:"
  puts e.backtrace.first(10).join("\n")
  false
end

puts '=' * 80
puts "Testing with Rails #{Rails.version}"
puts "Ruby version: #{RUBY_VERSION}"
puts '=' * 80

puts "\n\n#{'=' * 80}"
puts 'TEST 1: includes(options: [:creator], origin_field: { options: [:creator] })'
puts 'This previously FAILED without the fix, should now PASS'
puts '=' * 80
result = SurveyField.where(survey: true).includes(options: [:creator], origin_field: { options: [:creator] }).to_a
test1_passed = execute(result, 'TEST 1')

puts "\n\n#{'=' * 80}"
puts 'TEST 2: includes(:options, origin_field: :options) - Always worked correctly'
puts '=' * 80
result = SurveyField.where(survey: true).includes(:options, origin_field: :options).to_a
test2_passed = execute(result, 'TEST 2')

puts "\n\n#{'=' * 80}"
puts 'FINAL RESULTS'
puts '=' * 80
puts "TEST 1 (nested hash syntax): #{test1_passed ? '✅ PASSED' : '❌ FAILED'}"
puts "TEST 2 (array syntax):        #{test2_passed ? '✅ PASSED' : '❌ FAILED'}"
puts '=' * 80

if test1_passed && test2_passed
  puts "\n🎉 SUCCESS! The proposed fix works correctly!"
  puts 'Both tests passed - classes are instantiated correctly.'
else
  puts "\n❌ FAILURE! The fix did not resolve the issue."
  puts 'Please review the output above for details.'
end

puts "\n=== Test Complete ===\n"
