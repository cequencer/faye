module Faye
  class Server
    def initialize
      @channels = Channel::Tree.new
      @clients  = {}
    end
    
    def destroy!
      @clients.each { |id, client| client.disconnect! }
      @clients.clear
    end
    
    def process(messages, local = false, &callback)
      messages = [messages].flatten
      processed, responses = 0, []
      
      messages.each do |message|
        handle(message, local) do |reply|
          reply = [reply].flatten
          responses.concat(reply)
          processed += 1
          callback[responses] if processed == messages.size
        end
      end
    end
    
    def handle(message, local = false, &callback)
      channel = message['channel']
      
      if Channel.meta?(channel)
        response = __send__(Channel.parse(channel)[1], message)
        return callback[response] unless response['channel'] == Channel::CONNECT and
                                         response['successful'] == true
        
        return connection(response['clientId']).poll_events do |events|
          callback[[response] + events]
        end
      end
      
      return callback[[]] if message['clientId'].nil? or Channel.service?(channel)
      
      @channels.glob(channel).each { |c| c << message }
      
      callback[ { 'channel'     => channel,
                  'successful'  => true,
                  'id'          => message['id']  } ]
    end
    
    # MUST contain  * version
    #               * supportedConnectionTypes
    # MAY contain   * minimumVersion
    #               * ext
    #               * id
    def handshake(message, local = false)
      response =  { 'channel' => Channel::HANDSHAKE,
                    'version' => BAYEUX_VERSION,
                    'supportedConnectionTypes' => CONNECTION_TYPES,
                    'id'      => message['id'] }
      
      response['error'] = Error.parameter_missing('version') if message['version'].nil?
      
      client_conns = message['supportedConnectionTypes']
      if client_conns
        common_conns = client_conns.select { |c| CONNECTION_TYPES.include?(c) }
        response['error'] = Error.conntype_mismatch(*client_conns) if common_conns.empty?
      else
        response['error'] = Error.parameter_missing('supportedConnectionTypes')
      end
      
      response['successful'] = response['error'].nil?
      return response unless response['successful']
      
      response['clientId'] = generate_id
      response
    end
    
    # MUST contain  * clientId
    #               * connectionType
    # MAY contain   * ext
    #               * id
    def connect(message, local = false)
      response  = { 'channel' => Channel::CONNECT,
                    'id'      => message['id'] }
      client_id = message['clientId']
      
      response['error'] = Error.parameter_missing('clientId') if client_id.nil?
      response['error'] = Error.parameter_missing('connectionType') if message['connectionType'].nil?
      
      response['successful'] = response['error'].nil?
      return response unless response['successful']
      
      client = connection(client_id)
      response['clientId'] = client.id
      response
    end
    
    # MUST contain  * clientId
    # MAY contain   * ext
    #               * id
    def disconnect(message, local = false)
      response  = { 'channel' => Channel::DISCONNECT,
                    'id'      => message['id'] }
      client_id = message['clientId']
      client    = client_id ? @clients[client_id] : nil
      
      response['error'] = Error.client_unknown(client_id) if client.nil?
      response['error'] = Error.parameter_missing('clientId') if client_id.nil?
      
      response['successful'] = response['error'].nil?
      return response unless response['successful']
      
      client.disconnect!
      @clients.delete(client_id)
      
      response['clientId'] = client_id
      response
    end
    
    # MUST contain  * clientId
    #               * subscription
    # MAY contain   * ext
    #               * id
    def subscribe(message, local = false)
      response      = { 'channel'   => Channel::SUBSCRIBE,
                        'clientId'  => message['clientId'],
                        'id'        => message['id'] }
      
      client_id     = message['clientId']
      client        = client_id ? @clients[client_id] : nil
      
      subscription  = message['subscription']
      subscription  = [subscription].flatten
      
      response['error'] = Error.client_unknown(client_id) if client.nil?
      response['error'] = Error.parameter_missing('clientId') if client_id.nil?
      response['error'] = Error.parameter_missing('subscription') if message['subscription'].nil?
      
      response['subscription'] = subscription.compact
      
      subscription.each do |channel|
        next if response['error']
        response['error'] = Error.channel_forbidden(channel) unless Channel.subscribable?(channel)
        response['error'] = Error.channel_invalid(channel) unless Channel.valid?(channel)
        
        next if response['error']
        channel = @channels[channel] ||= Channel.new(channel)
        client.subscribe(channel)
      end
      
      response['successful'] = response['error'].nil?
      response
    end
    
    # MUST contain  * clientId
    #               * subscription
    # MAY contain   * ext
    #               * id
    def unsubscribe(message, local = false)
      response      = { 'channel'   => Channel::UNSUBSCRIBE,
                        'clientId'  => message['clientId'],
                        'id'        => message['id'] }
      
      client_id     = message['clientId']
      client        = client_id ? @clients[client_id] : nil
      
      subscription  = message['subscription']
      subscription  = [subscription].flatten
      
      response['error'] = Error.client_unknown(client_id) if client.nil?
      response['error'] = Error.parameter_missing('clientId') if client_id.nil?
      response['error'] = Error.parameter_missing('subscription') if message['subscription'].nil?
      
      response['subscription'] = subscription.compact
      
      subscription.each do |channel|
        next if response['error']
        
        if not Channel.valid?(channel)
          response['error'] = Error.channel_invalid(channel)
          next
        end
        
        channel = @channels[channel]
        client.unsubscribe(channel) if channel
      end
      
      response['successful'] = response['error'].nil?
      response
    end
    
    def client_ids
      @clients.keys
    end
    
  private
    
    def generate_id
      id = Faye.random
      id = Faye.random while @clients.has_key?(id)
      connection(id).id
    end
    
    def connection(id)
      @clients[id] ||= Connection.new(id)
    end
  end
end

