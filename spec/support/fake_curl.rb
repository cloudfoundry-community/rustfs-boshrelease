#!/usr/bin/env ruby
# A stand-in for curl that the lifecycle specs put first on PATH.
#
# FAKE_CURL_DIR/responses.json maps "<host>:<port><path>" to a list of
# [status, body] pairs.  Each call takes the next pair, and the last pair
# repeats.  Status 0 means no response, which curl reports as exit 7.
# Every call appends its arguments, one JSON array per line, to
# FAKE_CURL_DIR/calls.log.
require 'json'
require 'uri'

dir = ENV.fetch('FAKE_CURL_DIR')
File.open(File.join(dir, 'calls.log'), 'a') { |f| f.puts(JSON.generate(ARGV)) }

fail_on_error = false
out_file = nil
write_out = nil
url = nil
args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when '-o' then out_file = args.shift
  when '-w' then write_out = args.shift
  when '-H', '--cacert', '--connect-timeout', '--max-time' then args.shift
  when %r{\Ahttps?://} then url = arg
  when /\A-[a-zA-Z]+\z/ then fail_on_error ||= arg.include?('f')
  end
end

uri = URI.parse(url)
key = "#{uri.host.delete('[]')}:#{uri.port}#{uri.path}"
responses = JSON.parse(File.read(File.join(dir, 'responses.json')))
list = responses[key] || responses["*#{uri.path}"] || [[0, '']]

counter = File.join(dir, "count-#{key.gsub(/[^A-Za-z0-9]/, '_')}")
n = File.exist?(counter) ? File.read(counter).to_i : 0
File.write(counter, (n + 1).to_s)
status, body = list[[n, list.length - 1].min]

emit_write_out = lambda do |code|
  next unless write_out
  print write_out.gsub('\n', "\n").gsub('%{http_code}', format('%03d', code))
end

if status.zero?
  emit_write_out.call(0)
  exit 7
end
if fail_on_error && status >= 400
  exit 22
end
if out_file
  File.write(out_file, body) unless out_file == '/dev/null'
else
  print body
end
emit_write_out.call(status)
exit 0
