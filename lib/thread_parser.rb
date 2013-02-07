require 'resque'
require 'cgi'
require_relative '../init'
require_relative './user_mailer'

module ThreadParser

  class Worker
    @queue = :parsers

    def self.perform(args)
      conversation = Conversation.get(args['id'])
      parser = ThreadParser::Parser.new(conversation.plain)
      new parser, conversation, args['send_email']
    end

    def initialize(parser, conversation, send_email=false)
      @parser = parser
      @conversation = conversation
      @send_email = send_email
      call
    end

    def call
      @conversation.subject = @parser.extract_subject(@conversation.subject)
      @conversation.sender = @conversation.sender.gsub(/[\[\]'"]/, '')
      @parser.parse_thread
      save_to_db
      mail_sender if @send_email
    end

    def save_to_db
      Conversation.transaction do
        @parser.messages.reverse.each do |message_hash|
          message_attrs = {
            conversation: @conversation,
            body: message_hash[:message],
            sent: message_hash[:sent],
            sender: message_hash[:sender]
          }
          message = Message.create(message_attrs)
          message_hash[:headers].each_pair do |key, value|
            Header.create(message: message, field: key, value: value)
          end
        end

        expiry = Time.now + 86400
        @conversation.update(parsed: true, expires_at: expiry)
      end
    end

    def mail_sender
      Resque::enqueue(UserMailer::ConversationReady, @conversation.id)
    end

  end

  class Parser

    attr_accessor :subject, :messages

    def initialize(message)
      @raw_message = message
    end

    def parse_thread
      extract_messages(@raw_message)
      @messages.each do |message|
        extract_date_and_sender(message)
      end
    end

    def extract_subject(raw_subject)
      m = /^\s*\**\s*(?:(?:re|fw|fwd)\s*:)?\**\s*(.*)$/i.match(raw_subject)
      @subject = m.nil? ? raw_subject : m[1]
    end

    private #==================================================================

    def extract_messages(text)
      is_new_message = true
      message = new_message
      @messages = []

      lines = text.split("\n").to_enum
      next_line = get_next_line(lines)
      until next_line.nil? do
        line = next_line
        next_line = get_next_line(lines)

        if line.empty? && (is_new_message || next_line.nil? || next_line.empty?)
          next
        end

        if !is_new_message &&
           (is_splitter?(line) || is_splitter?("#{line} #{next_line}") || is_header?(line))
          is_new_message = true
          message[:message].strip!
          @messages << message unless message[:message].empty?
          message = new_message
        end

        if is_header?(line)
          begin
            unless next_line.nil? || next_line.empty? || is_header?(next_line)
              line << next_line
              next_line = get_next_line(lines)
            end
          end until next_line.nil? || next_line.empty? || is_header?(next_line)

          if next_line.nil? || next_line.empty?
            is_new_mesage = false
          end

          header, value = extract_header(line)
          message[:headers][header.strip.downcase.gsub(' ', '-')] = value
        elsif is_splitter?(line)
          message[:splitter] = line
        elsif is_splitter?("#{line} #{next_line}")
          message[:splitter] = "#{line} #{next_line}"
          next_line = get_next_line(lines)
        else
          is_new_message = false
          message[:message] << "#{line}\n"
        end
      end

      message[:message].strip!
      @messages << message unless message[:message].empty?
    end

    def get_next_line(lines)
      begin
        process_line(lines.next)
      rescue StopIteration
        nil
      end
    end

    def process_line(line)
      line = line.chomp
      match_data = /([\s>]*)(.*)/.match(line)
      return match_data[2] #, match_data[1].count('>')
    end

    def new_message
      {
        message: '',
        splitter: '',
        headers: {}
      }
    end

    def match_header(line)
      # From http://www.google.com/patents?hl=en&lr=&vid=USPAT7103599&id=b7J6AAAAEBAJ&oi=fnd&dq=nested+email&printsec=abstract#v=onepage&q=nested%20email&f=false
      header_keywords = %w{
        received from to cc bcc subject date sent x-mailer message-id content-type
        content-type content-transfer-encoding x-reply-to x-accept-language
        x-mozilla-status x-mozilla-status2 x-autoresponder-revision x-uidl
        organization mime-version reply-to
      }
      re = Regexp.new("^\\**\s*(#{header_keywords.join('|').gsub('-', '[\s\-]')}):\s*\\**\s*(.+)", 'i')
      re.match(line)
    end

    def extract_header(line)
      m = match_header(line)
      unless m.nil?
        m[1, 2]
      end
    end

    def is_header?(line)
      match_header(line) != nil
    end

    def is_splitter?(line)
      # From http://www.ceas.cc/2006/7.pdf
      splitter_expressions = [
        '(?:-{5,})',
        '(?:-*\s*(?:begin )?forwarded message:?\s*-*)',
        '(?:-*\s*original message:?\s*-*)',
        '(?:-*\s*on .* wrote:\s*-*)'
      ]
      re = Regexp.new("^(#{splitter_expressions.join('|')})\s*.*$", 'i')
      re.match(line) != nil
    end

    def parse_splitter(splitter)
      # Reg exes… heavy
      days = %w{ sun sunday mon monday tue tues tuesday wed weds wednesday
                 thu thur thurs thursday fri friday sat saturday }
      months = %w{ jan january feb february mar march apr april may jun june
                   jul july aug august sep sept september oct october nov
                   november dec december }
      day_exp = "(?:#{days.join('|')})?"
      date_exp1 = "(?:[0-9]{1,2},?\s+(?:#{months.join('|')})\s*,?\s*[0-9]{0,4})"
      date_exp2 = "(?:(?:#{months.join('|')})\s+[0-9]{1,2}\s*,?\s*[0-9]{0,4})"
      time_exp = "[0-1]?[0-9]:[0-9]{2}(?::[0-9]{2})?\s*(?:am|pm)?"
      datetime_exp = "#{day_exp},?\s*(?:#{date_exp1}|#{date_exp2})?,?\s+(?:at\s+)?(?:#{time_exp})?"

      if (m = /^-*\s*on (.*) wrote:\s*-*/i.match(splitter))
        date_re = Regexp.new("(#{datetime_exp}),?\s*(.*)", 'i')
        date_sender = date_re.match(m[1])
        return date_sender[1, 2] unless date_sender.nil?
      else
        return nil, nil
      end
    end

    def extract_date_and_sender(message)
      sender = ''

      message[:sent] = if message[:headers]['date']
                         message[:headers]['date']
                       elsif message[:headers]['sent']
                         message[:headers]['sent']
                       elsif message[:splitter]
                         date, sender = parse_splitter(message[:splitter])
                         date
                       else
                         nil
                       end

      message[:sender] = if message[:headers]['from']
                           message[:headers]['from']
                         elsif sender != ''
                           sender # retrieved from splitter above
                         elsif message[:headers]['reply-to']
                           message[:headers]['reply-to']
                         else
                           ''
                         end
    end

  end

end
