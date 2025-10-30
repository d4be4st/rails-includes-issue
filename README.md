# Rails Association Preloading Bug

## Summary

This repository demonstrates a bug in Rails 7.x's association preloading mechanism that occurs when using nested hash syntax with `includes()`.

## The Bug

### When It Occurs

The bug manifests when:
1. Two models share the same database table (e.g., STI-like pattern)
2. Both have associations with the **same name** (e.g., `options`)
3. But with **different `class_name` values**
4. You use **nested hash syntax** for eager loading: `includes(options: [], origin_field: { options: [] })`

### Example

```ruby
class SurveyField < ActiveRecord::Base
  self.table_name = 'custom_fields'
  has_many :options, foreign_key: :custom_field_id, class_name: 'SurveyFieldOption'
  belongs_to :origin_field, class_name: 'CustomField', optional: true
end

class CustomField < ActiveRecord::Base
  self.table_name = 'custom_fields'
  has_many :options, class_name: 'CustomFieldOption'
end

# BROKEN - Returns wrong classes
SurveyField.includes(options: [], origin_field: { options: [] })
# origin_field.options returns SurveyFieldOption instead of CustomFieldOption!

# WORKS - Correct classes
SurveyField.includes(:options, origin_field: :options)
# origin_field.options correctly returns CustomFieldOption
```

## Quick Start

### Run the Debug Script

```bash
ruby rails_bug_debug.rb
```

This will show:
- ✅ Debug output showing where Rails batches queries
- ❌ Class mismatches when they occur
- 🏗️ Record building with class information
- SQL queries executed

### Test with Different Rails Versions

```bash
# Test with Rails 7.2 (default)
ruby rails_bug_debug.rb

# Test with Rails 7.1
RAILS_VERSION=7.1 ruby rails_bug_debug.rb

# Test with Rails 7.0
RAILS_VERSION=7.0 ruby rails_bug_debug.rb

# Test with Rails 6.1 (works correctly)
RAILS_VERSION=6.1 ruby rails_bug_debug.rb
```

### Expected Results

#### Rails 7.x (BROKEN ❌)
```
❌ CLASS MISMATCH! Expected CustomFieldOption, got SurveyFieldOption
```

You'll see the debug output showing that Rails batches the queries:
```sql
SELECT * FROM custom_field_options WHERE custom_field_id IN (1, 2)
```

But uses `SurveyFieldOption` class for ALL records, even those belonging to `CustomField`.

#### Rails 6.1 (WORKS ✅)
```
✅ DEBUG: Associate 2 records to owner
```

Rails 6.1 executes separate queries:
```sql
SELECT * FROM custom_field_options WHERE custom_field_id = 2  -- SurveyFieldOption
SELECT * FROM custom_field_options WHERE custom_field_id = 1  -- CustomFieldOption
```

## Root Cause

The bug is in `ActiveRecord::Associations::Preloader::Batch#group_and_load_similar` (line 41 in Rails 7.2.3).

**File**: `activerecord/lib/active_record/associations/preloader/batch.rb`

```ruby
def group_and_load_similar(loaders)
  loaders.grep_v(ThroughAssociation).group_by(&:loader_query).each_pair do |query, similar_loaders|
    query.load_records_in_batch(similar_loaders)
  end
end
```

The method batches associations by `loader_query`, which groups by:
- Table name
- Connection specification
- Query values (WHERE conditions)

**But it does NOT consider the target class (`klass`)**.

When Rails executes:
```sql
SELECT * FROM custom_field_options WHERE custom_field_id IN (1, 2)
```

It batches both:
- `CustomField#options` (should return `CustomFieldOption`)
- `SurveyField#options` (should return `SurveyFieldOption`)

Then it instantiates ALL records using the **first association's class** and distributes these pre-instantiated objects to both associations.

### Why LoaderQuery Doesn't Check Class

The `LoaderQuery#eql?` method (in `activerecord/lib/active_record/associations/preloader/association.rb`) is:

```ruby
def eql?(other)
  association_key_name == other.association_key_name &&
    scope.table_name == other.scope.table_name &&
    scope.connection_specification_name == other.scope.connection_specification_name &&
    scope.values_for_queries == other.scope.values_for_queries
end
```

Notice it checks `scope.table_name` but **not** `scope.klass`.

## Regression Information

- **Works in**: Rails 6.1.7.10 ✅
- **Broken in**: Rails 7.0.0+ ❌
- **Breaking commit**: `20b9bb1de075ebaa17137db2abdd64cc9b394aae`
- **Commit title**: "Intelligent batch preloading"
- **Date**: April 1, 2021
- **Authors**: John Hawthorn (@jhawthorn) and Dinah Shi

The new intelligent batching system groups queries by table name and foreign key but doesn't account for different model classes that share the same table (STI scenarios).

## Understanding the Debug Output

When you run `rails_bug_debug.rb`, you'll see:

### 1. Building Records
```
🏗️  DEBUG: Building 2 records
   Reflection: options -> SurveyFieldOption
   Klass: SurveyFieldOption
   Rows: id=3, custom_field_id=2; id=4, custom_field_id=2
   Built: SurveyFieldOption#3, SurveyFieldOption#4
```

This shows Rails building records with the correct class.

### 2. Class Mismatch (The Bug!)
```
❌ DEBUG: Associate 2 records to owner
   Owner: CustomField#1
   Reflection: options -> CustomFieldOption
   Records: SurveyFieldOption#1, SurveyFieldOption#2
   ⚠️  CLASS MISMATCH! Expected CustomFieldOption, got SurveyFieldOption
```

This shows Rails associating records of the **WRONG class** to the owner!

### 3. Correct Behavior
```
✅ DEBUG: Associate 2 records to owner
   Owner: SurveyField#2
   Reflection: options -> SurveyFieldOption
   Records: SurveyFieldOption#3, SurveyFieldOption#4
```

No mismatch indicator means the classes are correct.

## Workaround

Until Rails fixes this, use array syntax instead of nested hash syntax:

```ruby
# Instead of this (BROKEN):
SurveyField.includes(options: [], origin_field: { options: [] })

# Use this (WORKS):
SurveyField.includes(:options, origin_field: :options)
```

If you need to include nested associations on the options, you can still do that:

```ruby
# This works:
SurveyField.includes({ options: :creator }, { origin_field: { options: :creator } })
```

## Proposed Fix

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

Alternatively, modify `group_and_load_similar` to group by both query and klass:

```ruby
def group_and_load_similar(loaders)
  non_through = loaders.grep_v(ThroughAssociation)
  
  grouped = non_through.group_by do |loader|
    [loader.loader_query, loader.klass]
  end
  
  grouped.each do |(query, _klass), similar_loaders|
    query.load_records_in_batch(similar_loaders)
  end
end
```

## Reporting to Rails

See `GITHUB_ISSUE_TEMPLATE.md` for a complete bug report ready to submit to https://github.com/rails/rails/issues/new

## Files in This Repository

- `README.md` - This file
- `rails_bug_debug.rb` - Reproduction script with debug output
- `GITHUB_ISSUE_TEMPLATE.md` - Bug report template for Rails team

## System Requirements

- Ruby 2.7+ (Ruby 3.0+ recommended)
- Bundler (for inline gemfiles)

The script uses `bundler/inline` so no `bundle install` needed - just run it!

## Contributing

If you encounter this bug or have additional information:
1. Test the reproduction script with your Rails version
2. Share your findings
3. Help create a proper Rails PR with a fix

## License

MIT
