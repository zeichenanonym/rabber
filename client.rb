class Client
  def initialize(socket)
    @socket = socket
    @queue = Queue.new
    @next_element = nil
    @stream_id_counter = 0
    
    @user = nil
    
    @xml_output = Builder::XmlMarkup.new :target => @socket
    Thread.new {
      Thread.current.abort_on_exception = true
      REXML::Document.parse_stream @socket, self
      @queue.push [:connection_closed]
    }
  end
  
  def xmldecl(version, encoding, standalone)
  end
  
  def tag_start(name, attrs)
    @queue.push [:tag_start, name, attrs]
  end
  
  def text(content)
    @queue.push [:text, content]
  end
  
  def tag_end(name)
    @queue.push [:tag_end, name]
  end
  
  def next_element
    @next_element ||= @queue.pop
    raise ConnectionClosedError if @next_element.first == :connection_closed
    @next_element
  end
  
  def consume
    @next_element = nil
  end
  
  def expect_tag(expected_name = nil)
    start_type, start_name, attrs = next_element
    raise ArgumentError, "expected tag_start, got #{start_type} (#{start_name})" if start_type != :tag_start
    raise ArgumentError if expected_name and start_name != expected_name
    consume
    
    yield start_name, attrs if block_given?
    
    end_type, end_name = next_element
    raise ArgumentError if end_type != :tag_end
    raise ArgumentError if end_name != start_name
    consume
  end
  
  def expect_text
    type, content = next_element
    raise ArgumentError if type != :text
    consume
    content
  end
  
  def next_is_tag_end?
    next_element[0] == :tag_end
  end
  
  def next_is_text?
    next_element[0] == :text
  end
  
  def run
    begin
      expect_tag "stream:stream" do
        handle_stream
      end
    rescue ConnectionClosedError
      puts "Connection closed."
    end
  end
  
  def handle_stream
    @current_stream_id = @stream_id_counter
    @stream_id_counter += 1
    @nonce = nil
    
    @xml_output.instruct! :xml, :version => "1.0", :encoding => "UTF-8"
    @xml_output.stream :stream, "xmlns:stream" => "http://etherx.jabber.org/streams", "xmlns" => "jabber:client", "from" => "localhost", "id" => @current_stream_id, "xml:lang" => "en", "version" => "1.0" do
      
      @xml_output.stream :features do
        if @user.nil?
          @xml_output.mechanisms "xmlns" => "urn:ietf:params:xml:ns:xmpp-sasl" do
            @xml_output.mechanism "PLAIN"
            @xml_output.mechanism "DIGEST-MD5"
          end
          @xml_output.auth "xmlns" => "http://jabber.org/features/iq-auth"
        else
          @xml_output.bind "xmlns" => "urn:ietf:params:xml:ns:xmpp-bind"
          @xml_output.session "xmlns" => "urn:ietf:params:xml:ns:xmpp-session"
        end
      end
      
      loop do
        break if next_is_tag_end?
        
        expect_tag do |name, attrs|
          begin
            case name
            when "auth", "response", "iq", "presence", "message"
              __send__ "stanza_#{name}", attrs
            when "stream:stream"
              handle_stream
            else 
              raise ArgumentError, name
            end
          rescue SaslError => e
            @xml_output.failure "xmlns" => "urn:ietf:params:xml:ns:xmpp-sasl" do
              @xml_output.tag! e.to_s
            end
          end
        end
      end
    end
  end
  
  def stanza_auth(attrs)
    raise ArgumentError if @user
    
    case attrs["mechanism"]
    when "PLAIN"
      authzid, username, password = Base64.decode64(expect_text).split("\0")
      user = User.find_by_name username
      raise SaslError, "not-authorized" if user.password != password
      @user = user
      @xml_output.success "xmlns" => "urn:ietf:params:xml:ns:xmpp-sasl"
      
    when "DIGEST-MD5"
      begin # try subsequent authentication
        raise SaslError if not next_is_text?
        response = parse_comma_seperated_hash Base64.decode64(expect_text)
        user = User.find_by_name response["username"]
        authenticate_user user, response, user.digest_md5_nonce, user.digest_md5_nc + 1
      rescue SaslError # run normal challenge/response
        @xml_output.challenge "xmlns" => "urn:ietf:params:xml:ns:xmpp-sasl" do
          @nonce = SecureRandom.base64 30
          @xml_output.text! Base64.encode64("realm=\"localhost\",nonce=\"#{@nonce}\",qop=\"auth\",charset=utf-8,algorithm=md5-sess")
        end
      end
      
    else
      raise ArgumentError
    end
  end
  
  def stanza_response(attrs)
    response = parse_comma_seperated_hash Base64.decode64(expect_text)
    user = User.find_by_name response["username"]
    authenticate_user user, response, @nonce, 1
  end
  
  def authenticate_user(user, response, nonce, nc)
    raise SaslError, "not-authorized" if nonce.nil?
    raise SaslError, "not-authorized" if response["nonce"] != nonce
    raise SaslError, "not-authorized" if response["realm"] != "localhost"
    raise SaslError, "not-authorized" if response["digest-uri"] != "xmpp/localhost"
    raise SaslError, "not-authorized" if response["nc"].to_i != nc
    
    calc_digest = lambda { |a2|
      a0 = "#{user.name}:localhost:#{user.password}"
      a1 = "#{Digest::MD5.digest a0}:#{nonce}:#{response["cnonce"]}"
      Digest::MD5.hexdigest "#{Digest::MD5.hexdigest a1}:#{nonce}:#{response["nc"]}:#{response["cnonce"]}:#{response["qop"]}:#{Digest::MD5.hexdigest a2}"
    }
    raise SaslError, "not-authorized" if response["response"] != calc_digest.call("AUTHENTICATE:#{response["digest-uri"]}")
    
    user.digest_md5_nonce = nonce
    user.digest_md5_nc = nc
    user.save!
    @user = user
    @xml_output.success "xmlns" => "urn:ietf:params:xml:ns:xmpp-sasl" do
      response_value = calc_digest.call ":#{response["digest-uri"]}"
      @xml_output.text! Base64.encode64("rspauth=#{response_value}")
    end
  end
  
  def stanza_iq(attrs)
    case attrs["type"]
    when "set"
      expect_tag do |name2, attrs2|
        respond = lambda { |type, send_jid|
          @xml_output.iq "type" => type, "id" => attrs["id"], "to" => "localhost/#{@current_stream_id}" do
            @xml_output.__send__ name2, "xmlns" => attrs2["xmlns"] do
              @xml_output.jid "#{@user.name}@localhost/#{@current_stream_id}" if send_jid
            end
            yield if block_given?
          end
        }
        
        case name2
        when "bind"
          respond.call "result", true
        when "session"
          respond.call "result", true
        when "query"
          case attrs2["xmlns"]
          when "jabber:iq:roster"
            expect_tag "item" do |item_name, item_attrs|
              group = nil
              expect_tag "group" do
                group_name = expect_text
                group = RoasterGroup.first :conditions => ["user_id = ? AND name = ?", @user, group_name]
                if group.nil?
                  group = RoasterGroup.create :user => @user, :name => group_name
                end
              end
              RoasterEntry.create :roaster_group => group, :jid => item_attrs["jid"], :name => item_attrs["name"]
              respond.call "result", true
            end
          end
        else
          respond.call "error", false do
            @xml_output.error "type" => "cancel" do
              @xml_output.tag! "service-unavailable", "xmlns" => "urn:ietf:params:xml:ns:xmpp-stanzas"
            end
          end
          #raise ArgumentError, name2
        end
      end
    when "get"
      expect_tag do |name2, attrs2|
        respond = lambda { |type|
          @xml_output.iq "type" => type, "id" => attrs["id"], "to" => "localhost/#{@current_stream_id}" do
            @xml_output.__send__ name2, "xmlns" => attrs2["xmlns"]
            yield if block_given?
          end
        }
        
        case name2
        when "query"
          respond.call "result"
          # TODO transports
        when "vCard"
          respond.call "result"
          # TODO proper vCard
        when "ping"
          @xml_output.iq "type" => "result", "id" => attrs["id"], "to" => "localhost/#{@current_stream_id}"
        else
          respond.call "error" do
            @xml_output.error "type" => "cancel" do
              @xml_output.tag! "service-unavailable", "xmlns" => "urn:ietf:params:xml:ns:xmpp-stanzas"
            end
          end
          #raise ArgumentError, name2
        end
      end
    end    
  end
  
  def stanza_presence(attrs)
    loop do
      break if next_is_tag_end?
      expect_tag do |name2, attrs2|
        case name2
        when "status"
          expect_text do |status|
            @xml_output.iq "type" => "result", "id" => attrs["id"], "to" => "localhost/#{@current_stream_id}"
          end
        when "priority"
          expect_text do |priority|
            @xml_output.iq "type" => "result", "id" => attrs["id"], "to" => "localhost/#{@current_stream_id}"
          end
        when "c"
          # in: <c xmlns='http://jabber.org/protocol/caps' node='http://pidgin.im/caps' ver='2.5.5' ext='mood moodn nick nickn tune tunen avatarmeta avatardata bob avatar'/>
          # can be ignored in the beginning :)
        else
          raise ArgumentError, name2
        end
      end
    end
  end
  
  def stanza_message(attrs)
    case attrs["type"]
      # TODO Fix REXML ParseException on  ä ö ü
    when "chat"
      loop do
        break if next_is_tag_end?
        expect_tag do |name2, attrs2|                  
          case name2
          when "body"
            message = expect_text
          when "html"
            expect_tag do |name3, attrs3|
              case name3
              when "body"
                message_html = expect_text
              end
            end
          else
            raise ArgumentError, name2
          end  
        end
      end
    else
      raise ArgumentError, name
    end
  end
  
  def parse_comma_seperated_hash(data)
    entries = CSV.parse data, :col_sep => '=', :row_sep => ','
    hash = {}
    entries.each do |key, value|
      raise ArgumentError if hash.has_key? key
      hash[key] = value
    end
    hash
  end
end