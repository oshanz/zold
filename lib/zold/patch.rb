# frozen_string_literal: true

# Copyright (c) 2018-2019 Zerocracy, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'openssl'
require_relative 'log'
require_relative 'wallet'
require_relative 'signature'

# Patch.
#
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2018 Yegor Bugayenko
# License:: MIT
module Zold
  # A patch
  class Patch
    def initialize(wallets, log: Log::NULL)
      @wallets = wallets
      @txns = []
      @log = log
    end

    def to_s
      return 'nothing' if @txns.empty?
      "#{@txns.count} txns"
    end

    def join(wallet, baseline: true, legacy: false)
      if @id.nil?
        @id = wallet.id
        @key = wallet.key
        if baseline
          @txns = wallet.txns
          @log.debug("The baseline of #{wallet.id} is #{wallet.balance}/#{@txns.count}t")
        else
          @log.debug("The baseline of #{@txns.count} transactions ignored")
        end
        @network = wallet.network
      end
      unless wallet.network == @network
        @log.error("The wallet is from a different network '#{wallet.network}', ours is '#{@network}'")
        return
      end
      unless wallet.key == @key
        @log.error('Public key mismatch')
        return
      end
      unless wallet.id == @id
        @log.error("Wallet ID mismatch, ours is #{@id}, theirs is #{wallet.id}")
        return
      end
      wallet.txns.each do |txn|
        next if legacy && (txn.amount.positive? || txn.date > Time.now - 24 * 60 * 60)
        next if @txns.find { |t| t == txn }
        if txn.amount.negative?
          dup = @txns.find { |t| t.id == txn.id && t.amount.negative? }
          if dup
            @log.error("An attempt to overwrite existing transaction \"#{dup.to_text}\" \
with a new one \"#{txn.to_text}\" from #{wallet.mnemo}")
            next
          end
          balance = @txns.map(&:amount).map(&:to_i).inject(&:+).to_i
          if balance < txn.amount.to_i * -1 && !wallet.root?
            @log.error("The transaction ##{txn.id} attempts to make the balance of \
#{wallet.id}/#{Amount.new(zents: balance).to_zld}/#{@txns.size} negative: \"#{txn.to_text}\"")
            next
          end
          unless Signature.new(@network).valid?(@key, wallet.id, txn)
            @log.error("Invalid RSA signature at the transaction ##{txn.id} of #{wallet.id}: \"#{txn.to_text}\"")
            next
          end
        else
          dup = @txns.find { |t| t.id == txn.id && t.bnf == txn.bnf && t.amount.positive? }
          if dup
            @log.error("Overwriting \"#{dup.to_text}\" with \"#{txn.to_text}\" from #{wallet.mnemo} (same ID/BNF)")
            next
          end
          if !txn.sign.nil? && !txn.sign.empty?
            @log.error("RSA signature is redundant at ##{txn.id} of #{wallet.id}: \"#{txn.to_text}\"")
            next
          end
          unless wallet.prefix?(txn.prefix)
            @log.error("Payment prefix '#{txn.prefix}' doesn't match with the key of #{wallet.id}: \"#{txn.to_text}\"")
            next
          end
          unless @wallets.acq(txn.bnf, &:exists?)
            if block_given?
              yield(txn.bnf)
              unless @wallets.acq(txn.bnf, &:exists?)
                @log.error("Paying wallet #{txn.bnf} file is absent even after PULL: \"#{txn.to_text}\"")
                next
              end
            else
              @log.error("Paying wallet #{txn.bnf} file is absent and it's a \"shallow\" MERGE: #{txn.to_text}")
              next
            end
          end
          unless @wallets.acq(txn.bnf) { |p| p.includes_negative?(txn.id, wallet.id) }
            @log.error("The beneficiary #{@wallets.acq(txn.bnf, &:mnemo)} of #{@id} \
doesn't have this transaction: \"#{txn.to_text}\"")
            next
          end
        end
        @txns << txn
        @log.debug("Merged on top, balance is #{@txns.map(&:amount).inject(&:+)}: #{txn.to_text}")
      end
    end

    def empty?
      @id.nil?
    end

    # Returns TRUE if the file was actually modified
    def save(file, overwrite: false)
      raise 'You have to join at least one wallet in' if empty?
      before = ''
      before = OpenSSL::Digest::SHA256.file(file).hexdigest if File.exist?(file)
      wallet = Wallet.new(file)
      wallet.init(@id, @key, overwrite: overwrite, network: @network)
      File.open(file, 'a') do |f|
        @txns.each do |txn|
          f.print "#{txn}\n"
        end
      end
      wallet.refurbish
      after = OpenSSL::Digest::SHA256.file(file).hexdigest
      before != after
    end
  end
end
