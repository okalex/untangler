class Header
  include DataMapper::Resource
  belongs_to :message

  property :id, Serial
  property :field, String, length: 64
  property :value, String, length: 1024
end
