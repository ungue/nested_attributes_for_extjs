module NestedAttributesForExtjs
  module Macros

    included do
      class_attribute :nested_attributes_extjs_options, :instance_writer => false
      self.nested_attributes_extjs_options = {}
    end

    module ClassMethods
      REJECT_ALL_BLANK_PROC = proc { |attributes| attributes.all? { |_, value| value.blank? } }

      def accepts_nested_attributes_extjs_for(*attr_names)
        options = { :allow_destroy => true, :update_only => false, :id_in_key => true }
        options.update(attr_names.extract_options!)
        options.assert_valid_keys(:allow_destroy, :reject_if, :limit, :update_only, :id_in_key)
        options[:reject_if] = REJECT_ALL_BLANK_PROC if options[:reject_if] == :all_blank

        attr_names.each do |association_name|
          if reflection = reflect_on_association(association_name)
            reflection.options[:autosave] = true
            add_autosave_association_callbacks(reflection)
            nested_attributes_extjs_options[association_name.to_sym] = options
            type = (reflection.collection? ? :collection : :one_to_one)

            # def pirate_attributes=(attributes)
            #   assign_nested_attributes_extjs_for_one_to_one_association(:pirate, attributes)
            # end
            class_eval <<-EOS, __FILE__, __LINE__ + 1
              if method_defined?(:#{association_name}_attributes=)
                remove_method(:#{association_name}_attributes=)
              end
              def #{association_name}_attributes=(attributes)
                assign_nested_attributes_extjs_for_#{type}_association(:#{association_name}, attributes)
              end
            EOS
          else
            raise ArgumentError, "No association found for name `#{association_name}'. Has it been defined yet?"
          end
        end
      end
    end

    # Returns ActiveRecord::AutosaveAssociation::marked_for_destruction? It's
    # used in conjunction with fields_for to build a form element for the
    # destruction of this association.
    #
    # See ActionView::Helpers::FormHelper::fields_for for more info.
    unless method_defined?(:_destroy)
      def _destroy
        marked_for_destruction?
      end
    end

    private

    UNASSIGNABLE_KEYS = %w( id _destroy )


    def assign_nested_attributes_extjs_for_one_to_one_association(association_name, attributes)
      options = nested_attributes_extjs_options[association_name]
      attributes = attributes.with_indifferent_access

      remove_extjs_key(attributes)

      check_existing_record = (options[:update_only] || !attributes['id'].blank?)

      if check_existing_record && (record = send(association_name)) && (options[:update_only] || record.id.to_s == attributes['id'].to_s)
        assign_to_or_mark_for_destruction(record, attributes, options[:allow_destroy]) unless call_reject_if(association_name, attributes)
      elsif attributes['id'].present?
        raise_nested_attributes_record_not_found(association_name, attributes['id'])
      elsif !reject_new_record?(association_name, attributes)
        method = "build_#{association_name}"
        if respond_to?(method)
          send(method, attributes.except(*UNASSIGNABLE_KEYS))
        else
          raise ArgumentError, "Cannot build association #{association_name}. Are you trying to build a polymorphic one-to-one association?"
        end
      end
    end

    def assign_nested_attributes_extjs_for_collection_association(association_name, attributes_collection)
      options = nested_attributes_extjs_options[association_name]

      attributes_collection = [] if attributes_collection.blank?

      unless attributes_collection.is_a?(Hash) || attributes_collection.is_a?(Array)
        raise ArgumentError, "Hash or Array expected, got #{attributes_collection.class.name} (#{attributes_collection.inspect})"
      end

      if options[:limit] && attributes_collection.size > options[:limit]
        raise TooManyRecords, "Maximum #{options[:limit]} records are allowed. Got #{attributes_collection.size} records instead."
      end

      if attributes_collection.is_a? Hash
        attributes_collection = if options[:id_in_key]
                                  attributes_collection.map { |idkey, attributes| attributes.merge(:id => idkey) }
                                else
                                  attributes_collection.values
                                end
      end

      # Quitamos los ids incorrectos (provenientes de autogeneraciones de extjs)
      attributes_collection.each { |a| remove_extjs_key(a) }

      association = send(association_name)

      all_records = association.loaded? ? association.target : association
      
      mark_for_destruction_except(all_records, attributes_collection.map {|a| (a['id'] || a[:id]).try(:to_s) }.compact)

      attributes_collection.each do |attributes|
        attributes = attributes.with_indifferent_access

        if attributes['id'].blank?
          unless reject_new_record?(association_name, attributes)
            association.build(attributes.except(*UNASSIGNABLE_KEYS))
          end
        elsif existing_record = all_records.detect { |record| record.id.to_s == attributes['id'].to_s }
          unless association.loaded? || call_reject_if(association_name, attributes)

            target_record = association.target.detect { |record| record == existing_record }

            if target_record
              existing_record = target_record
            else
              association.add_to_target(existing_record)
            end
          end

          if !call_reject_if(association_name, attributes)
            assign_to_or_mark_for_destruction(existing_record, attributes, options[:allow_destroy])
          end
        else
          raise_nested_attributes_record_not_found(association_name, attributes['id'])
        end
      end
    end

    # Updates a record with the +attributes+ or marks it for destruction if
    # +allow_destroy+ is +true+ and has_destroy_flag? returns +true+.
    def assign_to_or_mark_for_destruction(record, attributes, allow_destroy)
      if has_destroy_flag?(attributes) && allow_destroy
        record.mark_for_destruction
      else
        record.attributes = attributes.except(*UNASSIGNABLE_KEYS)
      end
    end

    # Marca para destruccion los elementos de la coleccion que no existen en los identificadores pasados
    def mark_for_destruction_except(records, ids)
      records.select{ |r| !ids.include?(r.id.to_s) }.each { |r| r.mark_for_destruction }
    end

    def valid_id?(id)
      !!(id.to_s =~ /^\d+$/)
    end

    def remove_extjs_key(attributes)
      v = attributes[:id] || attributes['id']
      attributes.delete(:id) || attributes.delete('id') if v && !valid_id?(v)
    end

    # Determines if a hash contains a truthy _destroy key.
    def has_destroy_flag?(hash)
      ActiveRecord::ConnectionAdapters::Column.value_to_boolean(hash['_destroy'])
    end

    # Determines if a new record should be build by checking for
    # has_destroy_flag? or if a <tt>:reject_if</tt> proc exists for this
    # association and evaluates to +true+.
    def reject_new_record?(association_name, attributes)
      has_destroy_flag?(attributes) || call_reject_if(association_name, attributes)
    end

    def call_reject_if(association_name, attributes)
      case callback = nested_attributes_extjs_options[association_name][:reject_if]
      when Symbol
        method(callback).arity == 0 ? send(callback) : send(callback, attributes)
      when Proc
        callback.call(attributes)
      end
    end

    def raise_nested_attributes_record_not_found(association_name, record_id)
      reflection = self.class.reflect_on_association(association_name)
      raise ActiveRecord::RecordNotFound, "Couldn't find #{reflection.klass.name} with ID=#{record_id} for #{self.class.name} with ID=#{id}"
    end
  end
end
