require 'benchmark'
require 'zlib'
require 'active_support/core_ext/array/extract_options'
require 'active_support/core_ext/array/wrap'
require 'active_support/core_ext/benchmark'
require 'active_support/core_ext/exception'
require 'active_support/core_ext/class/attribute_accessors'
require 'active_support/core_ext/numeric/bytes'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/object/to_param'
require 'active_support/core_ext/string/inflections'

module ActiveSupport
  # See ActiveSupport::Cache::Store for documentation.
  module Cache
    autoload :FileStore, 'active_support/cache/file_store'
    autoload :MemoryStore, 'active_support/cache/memory_store'
    autoload :MemCacheStore, 'active_support/cache/mem_cache_store'
    autoload :SynchronizedMemoryStore, 'active_support/cache/synchronized_memory_store'
    autoload :CompressedMemCacheStore, 'active_support/cache/compressed_mem_cache_store'

    EMPTY_OPTIONS = {}.freeze

    # These options mean something to all cache implementations. Individual cache
    # implementations may support additional optons.
    UNIVERSAL_OPTIONS = [:namespace, :compress, :compress_threshold, :expires_in, :race_condition_ttl]

    module Strategy
      autoload :LocalCache, 'active_support/cache/strategy/local_cache'
    end

    # Creates a new CacheStore object according to the given options.
    #
    # If no arguments are passed to this method, then a new
    # ActiveSupport::Cache::MemoryStore object will be returned.
    #
    # If you pass a Symbol as the first argument, then a corresponding cache
    # store class under the ActiveSupport::Cache namespace will be created.
    # For example:
    #
    #   ActiveSupport::Cache.lookup_store(:memory_store)
    #   # => returns a new ActiveSupport::Cache::MemoryStore object
    #
    #   ActiveSupport::Cache.lookup_store(:mem_cache_store)
    #   # => returns a new ActiveSupport::Cache::MemCacheStore object
    #
    # Any additional arguments will be passed to the corresponding cache store
    # class's constructor:
    #
    #   ActiveSupport::Cache.lookup_store(:file_store, "/tmp/cache")
    #   # => same as: ActiveSupport::Cache::FileStore.new("/tmp/cache")
    #
    # If the first argument is not a Symbol, then it will simply be returned:
    #
    #   ActiveSupport::Cache.lookup_store(MyOwnCacheStore.new)
    #   # => returns MyOwnCacheStore.new
    def self.lookup_store(*store_option)
      store, *parameters = *Array.wrap(store_option).flatten

      case store
      when Symbol
        store_class_name = store.to_s.camelize
        store_class = ActiveSupport::Cache.const_get(store_class_name)
        store_class.new(*parameters)
      when nil
        ActiveSupport::Cache::MemoryStore.new
      else
        store
      end
    end

    def self.expand_cache_key(key, namespace = nil)
      expanded_cache_key = namespace ? "#{namespace}/" : ""

      prefix = ENV["RAILS_CACHE_ID"] || ENV["RAILS_APP_VERSION"]
      if prefix
        expanded_cache_key << "#{prefix}/"
      end

      expanded_cache_key <<
        if key.respond_to?(:cache_key)
          key.cache_key
        elsif key.is_a?(Array)
          if key.size > 1
            key.collect { |element| expand_cache_key(element) }.to_param
          else
            key.first.to_param
          end
        elsif key
          key.to_param
        end.to_s

      expanded_cache_key
    end

    # An abstract cache store class. There are multiple cache store
    # implementations, each having its own additional features. See the classes
    # under the ActiveSupport::Cache module, e.g.
    # ActiveSupport::Cache::MemCacheStore. MemCacheStore is currently the most
    # popular cache store for large production websites.
    #
    # Some implementations may not support all methods beyond the basic cache
    # methods of +fetch+, +write+, +read+, +exist?+, and +delete+.
    #
    # ActiveSupport::Cache::Store can store any serializable Ruby object.
    #
    #   cache = ActiveSupport::Cache::MemoryStore.new
    #
    #   cache.read("city")   # => nil
    #   cache.write("city", "Duckburgh")
    #   cache.read("city")   # => "Duckburgh"
    #
    # Keys are always translated into Strings and are case sensitive. When an
    # object is specified as a key, its +cache_key+ method will be called if it
    # is defined. Otherwise, the +to_param+ method will be called. Hashes and
    # Arrays can be used as keys. The elements will be delimited by slashes
    # and Hashes elements will be sorted by key so they are consistent.
    #
    #   cache.read("city") == cache.read(:city)   # => true
    #
    # Nil values can be cached.
    #
    # If your cache is on a shared infrastructure, you can define a namespace for
    # your cache entries. If a namespace is defined, it will be prefixed on to every
    # key. The namespace can be either a static value or a Proc. If it is a Proc, it
    # will be invoked when each key is evaluated so that you can use application logic
    # to invalidate keys.
    #
    #   cache.namespace = lambda { @last_mod_time }  # Set the namespace to a variable
    #   @last_mod_time = Time.now  # Invalidate the entire cache by changing namespace
    #
    # All caches support auto expiring content after a specified number of seconds.
    # To set the cache entry time to live, you can either specify +:expires_in+ as
    # an option to the constructor to have it affect all entries or to the +fetch+
    # or +write+ methods for just one entry.
    #
    #   cache = ActiveSupport::Cache::MemoryStore.new(:expire_in => 5.minutes)
    #   cache.write(key, value, :expire_in => 1.minute)  # Set a lower value for one entry
    #
    # Caches can also store values in a compressed format to save space and reduce
    # time spent sending data. Since there is some overhead, values must be large
    # enough to warrant compression. To turn on compression either pass
    # <tt>:compress => true</tt> in the initializer or to +fetch+ or +write+.
    # To specify the threshold at which to compress values, set
    # <tt>:compress_threshold</tt>. The default threshold is 32K.
    class Store

      cattr_accessor :logger, :instance_writer => true

      attr_reader :silence
      alias :silence? :silence

      # Create a new cache. The options will be passed to any write method calls except
      # for :namespace which can be used to set the global namespace for the cache.
      def initialize (options = nil)
        @options = options ? options.dup : {}
      end

      # Get the default options set when the cache was created.
      def options
        @options ||= {}
      end

      # Silence the logger.
      def silence!
        @silence = true
        self
      end

      # Silence the logger within a block.
      def mute
        previous_silence, @silence = defined?(@silence) && @silence, true
        yield
      ensure
        @silence = previous_silence
      end

      # Set to true if cache stores should be instrumented. By default is false.
      def self.instrument=(boolean)
        Thread.current[:instrument_cache_store] = boolean
      end

      def self.instrument
        Thread.current[:instrument_cache_store] || false
      end

      # Fetches data from the cache, using the given key. If there is data in
      # the cache with the given key, then that data is returned.
      #
      # If there is no such data in the cache (a cache miss occurred), then
      # then nil will be returned. However, if a block has been passed, then
      # that block will be run in the event of a cache miss. The return value
      # of the block will be written to the cache under the given cache key,
      # and that return value will be returned.
      #
      #   cache.write("today", "Monday")
      #   cache.fetch("today")  # => "Monday"
      #
      #   cache.fetch("city")   # => nil
      #   cache.fetch("city") do
      #     "Duckburgh"
      #   end
      #   cache.fetch("city")   # => "Duckburgh"
      #
      # You may also specify additional options via the +options+ argument.
      # Setting <tt>:force => true</tt> will force a cache miss:
      #
      #   cache.write("today", "Monday")
      #   cache.fetch("today", :force => true)  # => nil
      #
      # Setting <tt>:compress</tt> will store a large cache entry set by the call
      # in a compressed format.
      #
      # Setting <tt>:expires_in</tt> will set an expiration time on the cache
      # entry if it is set by call.
      #
      # Setting <tt>:race_condition_ttl</tt> will invoke logic on entries set with
      # an <tt>:expires_in</tt> option. If an entry is found in the cache that is
      # expired and it has been expired for less than the number of seconds specified
      # by this option and a block was passed to the method call, then the expiration
      # future time of the entry in the cache will be updated to that many seconds
      # in the and the block will be evaluated and written to the cache.
      #
      # This is very useful in situations where a cache entry is used very frequently
      # under heavy load. The first process to find an expired cache entry will then
      # become responsible for regenerating that entry while other processes continue
      # to use the slightly out of date entry. This can prevent race conditions where
      # too many processes are trying to regenerate the entry all at once. If the
      # process regenerating the entry errors out, the entry will be regenerated
      # after the specified number of seconds.
      #
      #   # Set all values to expire after one minute.
      #   cache = ActiveSupport::Cache::MemoryCache.new(:expires_in => 1.minute)
      #
      #   cache.write("foo", "original value")
      #   val_1 = nil
      #   val_2 = nil
      #   sleep 60
      #
      #   Thread.new do
      #     val_1 = cache.fetch("foo", :race_condition_ttl => 10) do
      #       sleep 1
      #       "new value 1"
      #     end
      #   end
      #
      #   Thread.new do
      #     val_2 = cache.fetch("foo", :race_condition_ttl => 10) do
      #       "new value 2"
      #     end
      #   end
      #
      #   # val_1 => "new value 1"
      #   # val_2 => "original value"
      #   # cache.fetch("foo") => "new value 1"
      #
      # Other options will be handled by the specific cache store implementation.
      # Internally, #fetch calls #read_entry, and calls #write_entry on a cache miss.
      # +options+ will be passed to the #read and #write calls.
      #
      # For example, MemCacheStore's #write method supports the +:raw+
      # option, which tells the memcached server to store all values as strings.
      # We can use this option with #fetch too:
      #
      #   cache = ActiveSupport::Cache::MemCacheStore.new
      #   cache.fetch("foo", :force => true, :raw => true) do
      #     :bar
      #   end
      #   cache.fetch("foo")  # => "bar"
      def fetch(name, options = nil, &block)
        options = merged_options(options)
        key = namespaced_key(name, options)
        entry = instrument(:read, name, options) { read_entry(key, options) } unless options[:force]
        if entry && entry.expired?
          race_ttl = options[:race_condition_ttl].to_f
          if race_ttl and Time.now.to_f - entry.expires_at <= race_ttl
            entry.expires_at = Time.now + race_ttl
            write_entry(key, entry, :expires_in => race_ttl * 2)
          else
            delete_entry(key, options)
          end
          entry = nil
        end

        if entry
          entry.value
        elsif block_given?
          result = instrument(:generate, name, options, &block)
          write(name, result, options)
          result
        end
      end

      # Fetches data from the cache, using the given key. If there is data in
      # the cache with the given key, then that data is returned. Otherwise,
      # nil is returned.
      #
      # Options are passed to the underlying cache implementation.
      def read(name, options = nil)
        options = merged_options(options)
        key = namespaced_key(name, options)
        instrument(:read, name, options) do
          entry = read_entry(key, options)
          if entry
            if entry.expired?
              delete_entry(key, options)
              nil
            else
              entry.value
            end
          else
            nil
          end
        end
      end

      # Read multiple values at once from the cache. Options can be passed
      # in the last argument.
      #
      # Some cache implementation may optimize this method.
      #
      # Returns a hash mapping the names provided to the values found.
      def read_multi(*names)
        options = names.extract_options!
        options = merged_options(options)
        results = {}
        names.each do |name|
          key = namespaced_key(name, options)
          entry = read_entry(key, options)
          if entry
            if entry.expired?
              delete_entry(key)
            else
              results[name] = entry.value
            end
          end
        end
        results
      end

      # Writes the given value to the cache, with the given key.
      #
      # You may also specify additional options via the +options+ argument.
      # The specific cache store implementation will decide what to do with
      # +options+.
      def write(name, value, options = nil)
        options = merged_options(options)
        instrument(:write, name, options) do
          entry = Entry.new(value, options)
          write_entry(namespaced_key(name, options), entry, options)
        end
      end

      # Delete an entry in the cache. Returns +true+ if there was an entry to delete.
      #
      # Options are passed to the underlying cache implementation.
      def delete(name, options = nil)
        options = merged_options(options)
        instrument(:delete, name) do
          delete_entry(namespaced_key(name, options), options)
        end
      end

      # Return true if the cache contains an entry with this name.
      #
      # Options are passed to the underlying cache implementation.
      def exist?(name, options = nil)
        options = merged_options(options)
        instrument(:exist?, name) do
          entry = read_entry(namespaced_key(name, options), options)
          if entry && !entry.expired?
            true
          else
            false
          end
        end
      end

      # Delete all entries whose keys match a pattern.
      #
      # Options are passed to the underlying cache implementation.
      #
      # Not all implementations may support +delete_matched+.
      def delete_matched(matcher, options = nil)
        raise NotImplementedError.new("#{self.class.name} does not support delete_matched")
      end

      # Increment an integer value in the cache.
      #
      # Options are passed to the underlying cache implementation.
      #
      # Not all implementations may support +delete_matched+.
      def increment(name, amount = 1, options = nil)
        raise NotImplementedError.new("#{self.class.name} does not support increment")
      end

      # Increment an integer value in the cache.
      #
      # Options are passed to the underlying cache implementation.
      #
      # Not all implementations may support +delete_matched+.
      def decrement(name, amount = 1, options = nil)
        raise NotImplementedError.new("#{self.class.name} does not support decrement")
      end

      # Cleanup the cache by removing expired entries. Not all cache implementations may
      # support this method.
      #
      # Options are passed to the underlying cache implementation.
      #
      # Not all implementations may support +delete_matched+.
      def cleanup(options = nil)
        raise NotImplementedError.new("#{self.class.name} does not support cleanup")
      end

      # Clear the entire cache. Not all cache implementations may support this method.
      # You should be careful with this method since it could affect other processes
      # if you are using a shared cache.
      #
      # Options are passed to the underlying cache implementation.
      #
      # Not all implementations may support +delete_matched+.
      def clear(options = nil)
        raise NotImplementedError.new("#{self.class.name} does not support clear")
      end

      protected
        # Add the namespace defined in the options to a pattern designed to match keys.
        # Implementations that support delete_matched should call this method to translate
        # a pattern that matches names into one that matches namespaced keys.
        def key_matcher(pattern, options)
          prefix = options[:namespace].is_a?(Proc) ? options[:namespace].call : options[:namespace]
          if prefix
            source = pattern.source
            if source.start_with?('^')
              source = source[1, source.length]
            else
              source = ".*#{source[0, source.length]}"
            end
            Regexp.new("^#{Regexp.escape(prefix)}:#{source}", pattern.options)
          else
            pattern
          end
        end

        # Read an entry from the cache implementation. Subclasses must implement this method.
        def read_entry(key, options) # :nodoc:
          raise NotImplementedError.new
        end

        # Write an entry to the cache implementation. Subclasses must implement this method.
        def write_entry(key, entry, options) # :nodoc:
          raise NotImplementedError.new
        end

        # Delete an entry from the cache implementation. Subclasses must implement this method.
        def delete_entry(key, options) # :nodoc:
          raise NotImplementedError.new
        end

      private
        # Merge the default options with ones specific to a method call.
        def merged_options(call_options) # :nodoc:
          if call_options
            options.merge(call_options)
          else
            options.dup
          end
        end

        # Expand a key to be a consistent string value. If the object responds to +cache_key+,
        # it will be called. Otherwise, the to_param method will be called. If the key is a
        # Hash, the keys will be sorted alphabetically.
        def expanded_key(key) # :nodoc:
          if key.respond_to?(:cache_key)
            key = key.cache_key.to_s
          elsif key.is_a?(Array)
            if key.size > 1
              key.collect{|element| expanded_key(element)}.to_param
            else
              key.first.to_param
            end
          elsif key.is_a?(Hash)
            key = key.to_a.sort{|a,b| a.first.to_s <=> b.first.to_s}.collect{|k,v| "#{k}=#{v}"}.to_param
          else
            key = key.to_param
          end
        end

        # Prefix a key with the namespace. The two values will be delimited with a colon.
        def namespaced_key(key, options)
          key = expanded_key(key)
          namespace = options[:namespace] if options
          prefix = namespace.is_a?(Proc) ? namespace.call : namespace
          key = "#{prefix}:#{key}" if prefix
          key
        end

        def instrument(operation, key, options = nil)
          log(operation, key, options)

          if self.class.instrument
            payload = { :key => key }
            payload.merge!(options) if options.is_a?(Hash)
            ActiveSupport::Notifications.instrument("active_support.cache_#{operation}", payload){ yield }
          else
            yield
          end
        end

        def log(operation, key, options = nil)
          return unless logger && logger.debug? && !silence?
          logger.debug("Cache #{operation}: #{key}#{options.blank? ? "" : " (#{options.inspect})"}")
        end
    end

    # Entry that is put into caches. It supports expiration time on entries and can compress values
    # to save space in the cache.
    class Entry
      attr_reader :created_at, :expires_in

      DEFAULT_COMPRESS_LIMIT = 16.kilobytes

      class << self
        # Create an entry with internal attributes set. This method is intended to be
        # used by implementations that store cache entries in a native format instead
        # of as serialized Ruby objects.
        def create (raw_value, created_at, options = {})
          entry = new(nil)
          entry.instance_variable_set(:@value, raw_value)
          entry.instance_variable_set(:@created_at, created_at.to_f)
          entry.instance_variable_set(:@compressed, !!options[:compressed])
          entry.instance_variable_set(:@expires_in, options[:expires_in])
          entry
        end
      end

      # Create a new cache entry for the specified value. Options supported are
      # +:compress+, +:compress_threshold+, and +:expires_in+.
      def initialize(value, options = {})
        @compressed = false
        @expires_in = options[:expires_in]
        @expires_in = @expires_in.to_f if @expires_in
        @created_at = Time.now.to_f
        if value
          if should_compress?(value, options)
            @value = Zlib::Deflate.deflate(Marshal.dump(value))
            @compressed = true
          else
            @value = value
          end
        else
          @value = nil
        end
      end

      # Get the raw value. This value may be serialized and compressed.
      def raw_value
        @value
      end

      # Get the value stored in the cache.
      def value
        if @value
          val = compressed? ? Marshal.load(Zlib::Inflate.inflate(@value)) : @value
          unless val.frozen?
            val.freeze rescue nil
          end
          val
        end
      end

      def compressed?
        @compressed
      end

      # Check if the entry is expired. The +expires_in+ parameter can override the
      # value set when the entry was created.
      def expired?
        if @expires_in && @created_at + @expires_in <= Time.now.to_f
          true
        else
          false
        end
      end

      # Set a new time to live on the entry so it expires at the given time.
      def expires_at=(time)
        if time
          @expires_in = time.to_f - @created_at
        else
          @expires_in = nil
        end
      end

      # Seconds since the epoch when the cache entry will expire.
      def expires_at
        @expires_in ? @created_at + @expires_in : nil
      end

      # Get the size of the cached value. This could be less than value.size
      # if the data is compressed.
      def size
        if @value.nil?
          0
        elsif @value.respond_to?(:bytesize)
          @value.bytesize
        else
          Marshal.dump(@value).bytesize
        end
      end

      private
        def should_compress?(value, options)
          if options[:compress] && value
            unless value.is_a?(Numeric)
              compress_threshold = options[:compress_threshold] || DEFAULT_COMPRESS_LIMIT
              serialized_value = value.is_a?(String) ? value : Marshal.dump(value)
              return true if serialized_value.size >= compress_threshold
            end
          end
          false
        end
    end
  end
end
