require 'open-uri'
require 'bitcoin'
include Bitcoin::Builder
include BitcoinRubyHelper
include TxHelper

class Toshi
  attr_reader :network, :url
  def initialize(network=BITCOIN_NETWORK)
    @network = network
    @url = self.class.get_url(@network) 
  end

  def online?
    begin
      call_api == not_found
    rescue Errno::ECONNREFUSED
      return false
    end
  end
  
  def status
    call_api('toshi.json')['status']
  end

  def address(address)
    check_address(address)
    call_api('addresses', address)   
  end

  def utxo(address)
    fake_utxo(address)
  end

  def real_utxo(address)
    check_address(address)
    call_api('addresses', address, 'unspent_outputs')
  end

  def fake_utxo(address)
    check_address(address)
    data = self.tx(address)
    return not_found if data == not_found
    extract_utxos(data, address)
  end

  def unconf
    call_api('transactions', 'unconfirmed')
  end

  def block(height_or_id=nil)    
    if (height_or_id.is_a? Integer) && (height_or_id > -1) || (height_or_id.is_a? String) && (height_or_id.length == 64)
      call_api('blocks',height_or_id)
    elsif height_or_id.nil?
      call_api('blocks','latest')
    else
      raise "block expected #{height_or_id} to be either a block height or a block id"
    end    
  end

  def count
    self.block['height']
  end

  def tx(id = nil, confirmations = nil)
    if confirmations.nil?
      get_tx(id)
    else
      txdata = get_tx(id)
      txdata = ([] << txdata) unless txdata.is_a? Array
      txdata.select{|t| t['confirmations'].to_i == confirmations.to_i}
    end
  end

  def txid(id = nil, confirmations = nil)
    txdata = self.tx(id, confirmations)
    if txdata.is_a? Array
      txdata.map{|t| t['hash']}
    else
      txdata['hash']
    end
  end

  def balance(address) 
    check_address(address)
    data = self.address(address)
    if data == not_found
      return {confirmed: 0, unconfirmed: 0} if data == not_found  
    else
      return {confirmed: data['balance'].to_i, unconfirmed: data['unconfirmed_balance'].to_i}
    end
  end

  def create_tx(utxo_txid,private_key,recipient_address,amount,fee, change_address=nil)
    key = get_key(private_key, @network)
    source_address = key.addr
    change_address = source_address if change_address.nil?
    utxo = self.tx(utxo_txid)    
    # figuring out the index and balance from the utxo txid and the private key
    utxo_data = utxo['outputs'].each_with_index.map{|o,i| {idx: i, amount: o['amount'] }if o['addresses'].include?(source_address)}.compact[0]
    balance = utxo_data[:amount]
    utxo_index = utxo_data[:idx]
    
    new_tx = build_tx do |t|
     
     t.input do |i|  
       i.prev_out Bitcoin::P::Tx.from_json(utxo.to_json)
       i.prev_out_index utxo_index    
       i.signature_key key    
     end    
     
     t.output do |o|  
       o.value amount # in satoshis    
       o.script {|s| s.recipient recipient_address }    
     end    
     
     t.output do |o|  
       o.value balance - amount - fee # in satoshis    
       o.script {|s| s.recipient change_address }    
     end    
    end
    new_tx   
  end

  def create_general_tx(utxo_txids,private_keys,recipient_addresses,amounts)
    keys = private_keys.map{|pk| get_key(pk, @network)}
    source_addresses = keys.map{|k| k.addr}
    utxos = utxo_txids.map{|utxo_txid| self.tx(utxo_txid) }
    # figuring out the index and balance from the utxo txid and the private key
    utxos_data = utxos.each_with_index.map{|utxo,n| utxo['outputs'].each_with_index.map{|o,i| {idx: i, amount: o['amount'] } if o['addresses'].include?(source_addresses[n])}.compact[0]}

    new_tx = build_tx do |t|
    
      utxos.each_with_index do |utxo, n|
        t.input do |i|
          i.prev_out Bitcoin::P::Tx.from_json(utxo.to_json)
          i.prev_out_index utxos_data[n][:idx]
          i.signature_key keys[n]
        end
      end

      recipient_addresses.each_with_index do |recipient,n|
        t.output do |o|
          o.value amounts[n] # in satoshis
          o.script {|s| s.recipient recipient }
        end
      end
    end
    new_tx   
  end

  def sendrawtx(rawtx)
    txhash = { "hex" => rawtx }
    ApiPoster.new(@url+'transactions',nil, {ssl: (@network.to_sym != :regtest)}, txhash.to_json )
  end

  def self.not_found
    "{error: 'not found'}".to_json
  end

  private

    def not_found
      self.class.not_found
    end

    def self.get_url(network=BITCOIN_NETWORK)
      case network.to_sym
      when :testnet
        return 'https://testnet3.toshi.io/api/v0/'
      when :bitcoin
        return 'https://bitcoin.toshi.io/api/v0/'
      when :regtest
        return "http://#{GLOBAL[:TOSHI_ADDRESS]}/api/v0/"
      else
        raise "Toshi Helper does not recognize the network #{network}"
      end 
    end

    def call_api(*args)
      query = args.join('/')+'?limit=999999'
      url = @url+query
      begin
       response = JSON.parse(open(url).read)
      rescue OpenURI::HTTPError
        response = not_found
      end
      return response
    end

    def check_address(address)
      raise 'Invalid Bitcoin Address' unless valid_address?(address,@network)  
    end

    def get_tx(id=nil)
      # id can be an address, txid, blockid (strings) or block-height (fixnum)
      if id.is_a? String
        case id.length
        when 26..35
          address = id      
          check_address(address)   
          data = call_api('addresses', address, 'transactions')
          if data == not_found
            not_found
          else
            (data['transactions'] || []).concat(data['unconfirmed_transactions'] || [])
          end
        when 64
          # first try txid, if not found, try blockid
          data = call_api('transactions',id)
          data = call_api('blocks',id,'transactions') if data == not_found
          if data == not_found
            return not_found
          else
            if data['transactions'] #we got a block
              data['transactions']
            else # we got a tx
              data
            end
          end
        else
          raise "Expected #{id} either a valid #{BITCOIN_NETWORK} address, txid, blockid"
        end      
      elsif id.is_a? Fixnum
        if id >= 0 && id <= self.count
          hash = self.block(id)['hash']
          data = call_api('blocks',hash,'transactions')
          return data['transactions']
        else
          raise "No block with this height"
        end
      elsif id.nil?
        hash = self.block['hash']
        data = call_api('blocks',hash,'transactions')
        return data['transactions']
      else
        raise "Expected #{id} to be either a valid #{BITCOIN_NETWORK} address, txid, blockid or block-height but it is of class #{id.class}"
      end
    end

end
