# Rails Association Preloading Bug

## Summary

This repository documents and provides a workaround for a bug in Rails 7.x's association preloading mechanism that occurs when using nested hash syntax with `includes`.

## The Bug

### When It Occurs

The bug manifests when:
1. Two models share the same database table (e.g., STI-like pattern)
2. Both have associations with the **same name** (e.g., `options`)
3. But with **different `class_name` values**
4. You use **nested hash syntax** for eager loading

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

# WORKS - But less convenient
SurveyField.includes(:options, origin_field: :options)
# origin_field.options correctly returns CustomFieldOption
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

Notice it checks `scope.table_name` but not `scope.klass`.

## Investigation Files

This repository contains several scripts documenting the investigation:

1. **`rails_bug_reproduction.rb`** - Initial reproduction of the bug
2. **`rails_bug_debug.rb`** - Debug version with patches to trace the issue
3. **`rails_bug_pinpoint.rb`** - Focused debugging to pinpoint the exact problem
4. **`rails_bug_workaround.rb`** - First attempt at creating a workaround
5. **`rails_bug_workaround_final.rb`** - Final working workaround with tests
6. **`preloader_fix_initializer.rb`** - Production-ready initializer for Rails apps

## The Workaround

### For Testing (Standalone Script)

Run `rails_bug_workaround_final.rb` to see the bug and the fix in action:

```bash
ruby rails_bug_workaround_final.rb
```

### For Production (Rails App)

Copy `preloader_fix_initializer.rb` to your Rails app's initializers:

```bash
cp preloader_fix_initializer.rb config/initializers/preloader_fix.rb
```

### How It Works

The patch modifies `group_and_load_similar` to group by **both** `loader_query` **and** target class name:

```ruby
module ActiveRecordPreloaderBatchFix
  def group_and_load_similar(loaders)
    non_through = loaders.grep_v(ActiveRecord::Associations::Preloader::ThroughAssociation)
    
    grouped = non_through.group_by do |loader|
      query = loader.send(:loader_query)
      klass = loader.instance_variable_get(:@klass)
      [query, klass.name]  # Group by BOTH query and class name
    end
    
    grouped.each do |(query, _klass_name), similar_loaders|
      query.load_records_in_batch(similar_loaders)
    end
  end
end

ActiveRecord::Associations::Preloader::Batch.prepend(ActiveRecordPreloaderBatchFix)
```

## Impact

### Benefits
- ✅ Fixes the bug - correct classes are returned
- ✅ No changes to application code required
- ✅ Works with both nested hash and array syntax

### Trade-offs
- ⚠️ May execute slightly more queries when multiple associations with different `class_name` values query the same table
- ⚠️ Trades a small performance cost for correctness

### Example Query Changes

**Without patch (BROKEN):**
```sql
-- One batched query (WRONG - uses wrong class)
SELECT * FROM custom_field_options WHERE custom_field_id IN (1, 2)
```

**With patch (CORRECT):**
```sql
-- Two separate queries (CORRECT - uses right classes)
SELECT * FROM custom_field_options WHERE custom_field_id = 2  -- SurveyFieldOption
SELECT * FROM custom_field_options WHERE custom_field_id = 1  -- CustomFieldOption
```

## Rails Versions

- **Tested on**: Rails 7.1.x, 7.2.3
- **Likely affected**: All Rails 7.x versions
- **Possibly affected**: Rails 6.x (needs verification)

## Next Steps

1. ✅ Document the bug
2. ✅ Create a workaround
3. ⬜ Report to Rails team with reproduction
4. ⬜ Create a failing test case for Rails
5. ⬜ Submit a proper fix to Rails

## Files in This Repository

```
.
├── README.md                          # This file
├── rails_bug_minimal_test.rb          # Minimal test case for Rails team
├── rails_bug_reproduction.rb          # Initial bug reproduction
├── rails_bug_debug.rb                 # Debug version with tracing
├── rails_bug_pinpoint.rb              # Pinpoint the exact issue
├── rails_bug_workaround.rb            # First workaround attempt
├── rails_bug_workaround_final.rb      # Final working workaround with tests
└── preloader_fix_initializer.rb       # Production-ready initializer
```

## Running the Tests

All scripts are standalone and use `bundler/inline`:

```bash
# Minimal test case (best for reporting to Rails)
ruby rails_bug_minimal_test.rb

# See the bug in detail
ruby rails_bug_reproduction.rb

# See where it happens
ruby rails_bug_pinpoint.rb

# See the fix in action
ruby rails_bug_workaround_final.rb
```

## Contributing

If you encounter this bug or have additional information:
1. Test the workaround in your application
2. Report your findings
3. Help create a proper Rails PR

## License

MIT
