require 'openssl'

class Conversation
  include DataMapper::Resource
  has n, :messages, constraint: :destroy

  property :id,         Serial
  property :subject,    String,   length: 256
  property :sender,     String,   length: 256
  property :plain,      Text
  property :raw_msg,    Text
  property :parsed,     Boolean,  default: false
  property :auth_token, String,   length: 48
  property :created_at, DateTime
  property :expires_at, DateTime

  before :create, :set_creation_time
  before :create, :generate_auth_token

  def set_creation_time
    self.created_at = Time.now
  end

  SALT = ENV.fetch('AUTH_TOKEN_SALT', 's.L0U]+Uoo-lNp||r=R+;x .++UWf[b1>=B{eY9QC05LR?^lAh@+): DU,Rfw)N~')
  def generate_auth_token()
    digest = OpenSSL::Digest::Digest.new('sha1')
    self.auth_token = OpenSSL::HMAC.hexdigest(digest, SALT, "#{rand(10)}#{Time.now.to_f}")
  end
end
