# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gamechanger::Signer do
  # Captured test vectors from live GC API auth flow (recorded 2026-05-18).
  # These verify the Ruby port of the JS signPayload algorithm produces
  # byte-identical signatures.
  let(:client_key) { 'gFN+/LbESwNuvsEYWAIyTMh5tn92KEeU4Rhhvbrrb1w=' }

  describe '.sign without previousSignature (client-auth)' do
    it 'reproduces the captured signature' do
      sig = described_class.sign(
        client_key: client_key,
        timestamp: '1779111503',
        nonce: 'mlWbtS84lXiYmSDy1FMpjQ+dW+BVKygxusErtQJ/2CY=',
        body: { type: 'client-auth', client_id: '7200841e-884d-4e23-825d-8a404a03b726' }
      )
      expect(sig).to eq(
        'mlWbtS84lXiYmSDy1FMpjQ+dW+BVKygxusErtQJ/2CY=' \
        '.BXBRV5Q+3+QVyR4TICIaacyLs89/HYnFCZwuP+HQadw='
      )
    end
  end

  describe '.sign with previousSignature chaining (user-auth)' do
    it 'reproduces the captured signature when chained to prior response' do
      sig = described_class.sign(
        client_key: client_key,
        timestamp: '1779111503',
        nonce: '5wSQ8nMivMcj9APGk0QqmvgvpnoIaDUg+GTaOJ3Ibdk=',
        body: { type: 'user-auth', email: 'joshua_powell@yahoo.com' },
        previous_signature: 'pQmQnLj/jZ5TgBONSGApQvjTPXcU7YUZlEeajGnkM5w='
      )
      expect(sig).to eq(
        '5wSQ8nMivMcj9APGk0QqmvgvpnoIaDUg+GTaOJ3Ibdk=' \
        '.7bsTlA8uSam0L4iqlc3pxgwV/GGjoUml27WP2htVAu4='
      )
    end
  end

  describe '.values_for_signer' do
    it 'sorts hash keys before extracting values' do
      expect(described_class.values_for_signer(b: 2, a: 'x', c: nil))
        .to eq(['x', '2', 'null'])
    end

    it 'recursively flattens nested hashes and arrays' do
      expect(described_class.values_for_signer(z: [1, { y: 'inner' }], a: 'top'))
        .to eq(['top', '1', 'inner'])
    end

    it 'stringifies numbers and accepts string or symbol keys' do
      expect(described_class.values_for_signer('n' => 42, :s => 'hi'))
        .to eq(['42', 'hi'])
    end
  end

  describe '.generate_nonce' do
    it 'returns a base64-encoded 32-byte value' do
      nonce = described_class.generate_nonce
      expect(Base64.decode64(nonce).bytesize).to eq(32)
    end

    it 'returns a distinct value on each call' do
      expect(described_class.generate_nonce).not_to eq(described_class.generate_nonce)
    end
  end

  describe '.previous_signature_from_response' do
    it 'returns the second half of the gc-signature header' do
      header = 'aaaa.bbbb'
      expect(described_class.previous_signature_from_response(header)).to eq('bbbb')
    end

    it 'returns nil for empty or nil input' do
      expect(described_class.previous_signature_from_response(nil)).to be_nil
      expect(described_class.previous_signature_from_response('')).to be_nil
    end
  end
end
