class Message
  include DataMapper::Resource
  belongs_to :conversation
  has n, :headers, constraint: :destroy

  property :id, Serial
  property :body, Text
  property :sent, String, length: 256
  property :sender, String, length: 256

  def pretty_date
    begin
      DateTime.parse(sent).strftime('%B %e, %Y at %l:%M %p')
    rescue ArgumentError
      sent
    end
  end
end
