# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'securerandom'

module Gamechanger
  # GC API request signing (HMAC-SHA256 with chained signatures).
  #
  # Every /auth POST requires a `gc-signature` header of the form
  # `<base64-nonce>.<base64-hmac>`. The HMAC covers:
  #
  #   "<timestamp>|" + <nonce-bytes> + "|" + <sorted-body-values-joined-by-|>
  #   [ + "|" + <previous-signature-bytes> ]
  #
  # `previous_signature` is the 2nd half of the prior response's gc-signature
  # header. This chains every signed request to the previous one so a captured
  # signature cannot be replayed out of order.
  module Signer
    module_function

    # @return [String] base64-encoded 32-byte nonce
    def generate_nonce
      Base64.strict_encode64(SecureRandom.random_bytes(32))
    end

    # Flatten a body into the ordered list of string values that go into the HMAC.
    # Mirrors the JS valuesForSigner: objects are walked in sorted-key order,
    # arrays flat-mapped, numbers stringified, undefined dropped, nil → "null".
    def values_for_signer(value)
      case value
      when Array
        value.flat_map { |v| values_for_signer(v) }
      when Hash
        value.keys.map(&:to_s).sort.flat_map do |k|
          v = value[k] || value[k.to_sym]
          values_for_signer(v)
        end
      when String
        [value]
      when Numeric
        [value.to_s]
      when nil
        ['null']
      else
        raise ArgumentError, "Unknown type for signer: #{value.class}"
      end
    end

    # Compute the gc-signature header value for a single request.
    #
    # @param client_key [String] base64-encoded HMAC key
    # @param timestamp [Integer, String] unix seconds
    # @param nonce [String] base64-encoded nonce (use generate_nonce)
    # @param body [Hash, nil] request body (nil for GET)
    # @param previous_signature [String, nil] base64-encoded prev-response sig (2nd half)
    # @return [String] `<nonce>.<hmac>` ready for the gc-signature header
    def sign(client_key:, timestamp:, nonce:, body:, previous_signature: nil)
      key   = Base64.decode64(client_key)
      hmac  = OpenSSL::HMAC.new(key, OpenSSL::Digest.new('SHA256'))
      hmac.update("#{timestamp}|")
      hmac.update(Base64.decode64(nonce))
      hmac.update('|')
      hmac.update(values_for_signer(body || {}).join('|'))
      if previous_signature && !previous_signature.empty?
        hmac.update('|')
        hmac.update(Base64.decode64(previous_signature))
      end

      "#{nonce}.#{Base64.strict_encode64(hmac.digest)}"
    end

    # Extract the chaining half of a gc-signature header value.
    # @param header_value [String, nil] full `<nonce>.<hmac>` header
    # @return [String, nil] the 2nd half (HMAC), or nil if header is empty
    def previous_signature_from_response(header_value)
      return nil if header_value.nil? || header_value.empty?

      parts = header_value.split('.', 2)
      parts[1]
    end
  end
end
