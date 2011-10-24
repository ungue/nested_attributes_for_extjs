require 'active_record'
require 'active_support/core_ext'
require 'active_support/concern'
require 'nested_attributes_for_extjs/macros'

ActiveRecord::Base.send :include, NestedAttributesForExtjs::Macros
