# GitHub Issue Template for Rails

Copy this template when reporting the bug to Rails: https://github.com/rails/rails/issues/new

---

## Bug Report: Incorrect class instantiation with nested includes() on associations with same table name

### Description

When two models share the same database table and have associations with the same name but different `class_name` values, Rails incorrectly instantiates all records using the first association's class when using nested hash syntax with `includes()`.

### Steps to Reproduce

```ruby
require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'
  gem 'rails', '~> 7.2'
  gem 'sqlite3'
end

require 'active_record'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Base.logger = nil

ActiveRecord::Schema.define do
  create_table :custom_fields, force: true do |t|
    t.integer :origin_field_id
  end

  create_table :custom_field_options, force: true do |t|
    t.integer :custom_field_id
  end
end

class SurveyField < ActiveRecord::Base
  self.table_name = 'custom_fields'
  has_many :options, foreign_key: :custom_field_id, class_name: 'SurveyFieldOption'
  belongs_to :origin_field, class_name: 'CustomField', optional: true
end

class SurveyFieldOption < ActiveRecord::Base
  self.table_name = 'custom_field_options'
end

class CustomField < ActiveRecord::Base
  self.table_name = 'custom_fields'
  has_many :options, class_name: 'CustomFieldOption'
end

class CustomFieldOption < ActiveRecord::Base
  self.table_name = 'custom_field_options'
end

# Create test data
origin = CustomField.create!
CustomFieldOption.create!(custom_field_id: origin.id)

survey = SurveyField.create!(origin_field_id: origin.id)
SurveyFieldOption.create!(custom_field_id: survey.id)

# This returns WRONG class for origin_field.options
result = SurveyField.includes(options: [], origin_field: { options: [] }).first
puts result.origin_field.options.first.class
# => SurveyFieldOption (WRONG - should be CustomFieldOption)

# This works correctly
result = SurveyField.includes(:options, origin_field: :options).first
puts result.origin_field.options.first.class
# => CustomFieldOption (CORRECT)
```

### Expected Behavior

```ruby
result = SurveyField.includes(options: [], origin_field: { options: [] }).first
result.origin_field.options.first.class
# => CustomFieldOption
```

### Actual Behavior

```ruby
result = SurveyField.includes(options: [], origin_field: { options: [] }).first
result.origin_field.options.first.class
# => SurveyFieldOption (WRONG!)
```

### Root Cause

The bug is in `ActiveRecord::Associations::Preloader::Batch#group_and_load_similar` (activerecord/lib/active_record/associations/preloader/batch.rb:41):

```ruby
def group_and_load_similar(loaders)
  loaders.grep_v(ThroughAssociation).group_by(&:loader_query).each_pair do |query, similar_loaders|
    query.load_records_in_batch(similar_loaders)
  end
end
```

The method groups loaders by `loader_query`, which checks table name, connection, and query values, but **NOT the target class** (`klass`). This causes associations that query the same table to be batched together even when they should instantiate different classes.

The `LoaderQuery#eql?` method (activerecord/lib/active_record/associations/preloader/association.rb) compares:
- `association_key_name`
- `scope.table_name`
- `scope.connection_specification_name`
- `scope.values_for_queries`

But it doesn't compare `scope.klass`, leading to incorrect batching.

### System Information

- Rails version: 7.2.3 (also affects 7.1.x, likely all 7.x)
- Ruby version: 3.2.9
- **Regression introduced in**: Rails 7.0.0 (works correctly in Rails 6.1.7.10)

### Breaking Commit

This regression was introduced by:

- **Commit**: `20b9bb1de075ebaa17137db2abdd64cc9b394aae`
- **Title**: "Intelligent batch preloading"
- **Date**: April 1, 2021
- **Authors**: John Hawthorn (@jhawthorn) and Dinah Shi
- **PR**: Added intelligent batching to optimize queries by grouping similar associations

The new batching system groups queries by table name and foreign key but doesn't account for different model classes that share the same table (STI scenarios). When `SurveyFieldOption` and `CustomFieldOption` share the `custom_field_options` table, the batcher incorrectly uses the first class encountered for all records in the batch.

### Workaround

Modify `group_and_load_similar` to group by both query AND target class:

```ruby
module ActiveRecordPreloaderBatchFix
  def group_and_load_similar(loaders)
    non_through = loaders.grep_v(ActiveRecord::Associations::Preloader::ThroughAssociation)
    
    grouped = non_through.group_by do |loader|
      [loader.loader_query, loader.klass]
    end
    
    grouped.each do |(query, _klass_name), similar_loaders|
      query.load_records_in_batch(similar_loaders)
    end
  end
end

ActiveRecord::Associations::Preloader::Batch.prepend(ActiveRecordPreloaderBatchFix)
```

### Proposed Fix

The `LoaderQuery#eql?` and `#hash` methods should include the target class in their comparison:

```ruby
def eql?(other)
  association_key_name == other.association_key_name &&
    scope.table_name == other.scope.table_name &&
    scope.klass == other.scope.klass &&  # ADD THIS LINE
    scope.connection_specification_name == other.scope.connection_specification_name &&
    scope.values_for_queries == other.scope.values_for_queries
end

def hash
  [association_key_name, scope.table_name, scope.klass, scope.connection_specification_name, scope.values_for_queries].hash
end
```

Alternatively, modify `group_and_load_similar` to group by both query and klass as shown in the workaround above.

### Full Reproduction Repository

Complete reproduction with tests and documentation: [Add your repo URL here]
