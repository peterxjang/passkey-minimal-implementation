require "sinatra"
require "sinatra/json"
require "webauthn"
require 'sqlite3'

enable :sessions

WebAuthn.configure do |config|
  config.allowed_origins = ["http://localhost:4567"]
  config.rp_name = "Example Inc."
end

db = SQLite3::Database.open 'relying_party.db'
db.execute "CREATE TABLE IF NOT EXISTS users(name TEXT UNIQUE, webauthn_id TEXT, public_key TEXT, sign_count INT)"
db.results_as_hash = true

get "/registration/options" do
  webauthn_id = WebAuthn.generate_user_id
  options = WebAuthn::Credential.options_for_create(
    user: { id: webauthn_id, name: params["name"] },
  )
  begin
    db.execute(
      "INSERT INTO users (name) VALUES (?)", 
      [params["name"]],
    )
  rescue SQLite3::Exception => e
    puts e
  end
  session[:registration_challenge] = options.challenge
  json options.as_json
end

post "/registration/result" do
  body_params = JSON.parse(request.body.read)
  webauthn_credential = WebAuthn::Credential.from_create(body_params)
  begin
    webauthn_credential.verify(session[:registration_challenge])
    db.execute(
      "UPDATE users SET webauthn_id=?, public_key=?, sign_count=? WHERE name=?", 
      [webauthn_credential.id, webauthn_credential.public_key, webauthn_credential.sign_count.to_i, params["name"]],
    )
    json message: "Success"
  rescue WebAuthn::Error => e
    json error: e
  end
end

get "/authentication/options" do
  options = WebAuthn::Credential.options_for_get(allow: [])
  session[:authentication_challenge] = options.challenge
  json options.as_json
end

post "/authentication/result" do
  body_params = JSON.parse(request.body.read)
  webauthn_credential = WebAuthn::Credential.from_get(body_params)
  user = db.get_first_row "SELECT public_key, sign_count FROM users WHERE webauthn_id=?", webauthn_credential.id
  return json error: "User not found" unless user
  begin
    webauthn_credential.verify(
      session[:authentication_challenge],
      public_key: user["public_key"],
      sign_count: user["sign_count"],
    )
    db.execute(
      "UPDATE users SET sign_count=? WHERE webauthn_id=?", 
      [webauthn_credential.sign_count.to_i, webauthn_credential.id],
    )
    json message: "Success"
  rescue WebAuthn::SignCountVerificationError => e
    json error: e
  rescue WebAuthn::Error => e
    json error: e
  end
end
