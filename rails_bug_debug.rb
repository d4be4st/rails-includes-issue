# frozen_string_literal: true

# Single-file Rails app to reproduce the includes issue with debug patches
# Run with: ruby rails_bug_debug.rb

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

# PATCH: Add debug logging to ActiveRecord preloader
module DebugPreloaderPatch
  def associate_records_to_owner(owner, records)
    mismatch = records.any? { |r| r.class.name != reflection.class_name }
    prefix = mismatch ? "❌" : "✅"
    
    puts "\n#{prefix} DEBUG: Associate #{records.size} records to owner"
    puts "   Owner: #{owner.class.name}##{owner.id}"
    puts "   Reflection: #{reflection.name} -> #{reflection.class_name}"
    puts "   Records: #{records.map { |r| "#{r.class.name}##{r.id}" }.join(', ')}"
    if mismatch
      puts "   ⚠️  CLASS MISMATCH! Expected #{reflection.class_name}, got #{records.first.class.name}"
    end
    
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

def execute(result)
  puts "\n=== Output ===\n"

  result.each do |record|
    puts "Record: id=#{record.id}, name='#{record.name}', class=#{record.class}"

    # Show options
    record.options.each do |option|
      puts "  Option: id=#{option.id}, value='#{option.value}', class=#{option.class}"
    end

    # Show origin_field if exists
    if record.origin_field
      puts "  OriginField: id=#{record.origin_field.id}, name='#{record.origin_field.name}', class=#{record.origin_field.class}"

      # Show origin_field options
      record.origin_field.options.each do |option|
        puts "    OriginOption: id=#{option.id}, value='#{option.value}', class=#{option.class}"
      end
    end
    puts ''
  end
rescue StandardError => e
  puts "\nERROR!"
  puts "Exception: #{e.class}"
  puts "Message: #{e.message}"
  puts "\nBacktrace:"
  puts e.backtrace.first(10).join("\n")
end

puts '=' * 80
puts "Testing with Rails #{Rails.version}"
puts "Ruby version: #{RUBY_VERSION}"
puts '=' * 80

puts "\n\n" + "=" * 80
puts "TEST 1: includes(options: [:creator], origin_field: { options: [:creator] })"
puts "=" * 80
result = SurveyField.where(survey: true).includes(options: [:creator], origin_field: { options: [:creator] }).to_a
execute(result)

puts "\n\n" + "=" * 80
puts "TEST 2: includes(:options, origin_field: :options) - CORRECT BEHAVIOR"
puts "=" * 80
result = SurveyField.where(survey: true).includes(:options, origin_field: :options).to_a
execute(result)

puts "\n=== Test Complete ===\n"
