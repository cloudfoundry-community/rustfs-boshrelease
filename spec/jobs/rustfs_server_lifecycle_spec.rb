require 'rspec'
require 'json'
require 'openssl'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'bosh/template/test'

# These specs run the rendered post-start, drain, and s3-read-probe scripts
# under bash, with a fake curl first on PATH and a sleep that returns at
# once.  The fake answers each URL from a scripted list of responses, so
# each example plays out one sequence of node states.
describe 'rustfs-server lifecycle scripts' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '../..')) }
  let(:job) { release.job('rustfs-server') }
  let(:fake_curl) { File.expand_path('../support/fake_curl.rb', __dir__) }
  let(:addrs) { %w[10.0.0.1 10.0.0.2 10.0.0.3] }
  let(:secret) { 'sEcReT/with+chars' }
  let(:props) do
    { 'rustfs' => { 'access_key' => 'AKTEST', 'secret_key' => secret,
                    'post_start' => { 'ready_timeout_secs' => 10 } } }
  end

  def peers(addresses)
    instances = addresses.each_with_index.map do |addr, i|
      Bosh::Template::Test::LinkInstance.new(id: "node-#{i}", index: i, address: addr)
    end
    [Bosh::Template::Test::Link.new(name: 'rustfs-peer', instances: instances,
                                    properties: { 'rustfs' => { 'port' => 9000 } })]
  end

  def node(addresses, index)
    Bosh::Template::Test::InstanceSpec.new(id: "node-#{index}", index: index,
                                           address: addresses[index], ip: addresses[index])
  end

  around do |example|
    Dir.mktmpdir('rustfs-lifecycle') do |dir|
      @dir = dir
      FileUtils.mkdir_p(File.join(dir, 'bin'))
      FileUtils.mkdir_p(File.join(dir, 'fake'))
      FileUtils.ln_s(fake_curl, File.join(dir, 'bin', 'curl'))
      File.write(File.join(dir, 'bin', 'sleep'), "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, File.join(dir, 'bin', 'sleep'))
      example.run
    end
  end

  def respond(map)
    File.write(File.join(@dir, 'fake', 'responses.json'), JSON.generate(map))
  end

  def calls
    path = File.join(@dir, 'fake', 'calls.log')
    File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  # render writes a template to the job directory under @dir, pointing every
  # job path at that directory, and returns its path.
  def render(template, properties, spec, consumes, name)
    out = job.template(template).render(properties, spec: spec, consumes: consumes)
    out = out.gsub('/var/vcap/jobs/rustfs-server', File.join(@dir, 'job'))
             .gsub('/var/vcap/sys/log/rustfs-server', File.join(@dir, 'log'))
             .gsub('/var/vcap/data/rustfs-server', File.join(@dir, 'data'))
    path = File.join(@dir, 'job', 'bin', name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, out)
    FileUtils.chmod(0o755, path)
    path
  end

  def run(path, *args)
    # bundle exec exports RUBYOPT, which would make every fake curl call
    # load bundler, so the scripts run without it.
    env = { 'PATH' => "#{File.join(@dir, 'bin')}:#{ENV['PATH']}", 'FAKE_CURL_DIR' => File.join(@dir, 'fake'),
            'RUBYOPT' => nil, 'RUBYLIB' => nil, 'BUNDLE_GEMFILE' => nil, 'BUNDLE_BIN_PATH' => nil }
    Open3.capture3(env, 'bash', path, *args)
  end

  # stub_read_probe replaces bin/s3-read-probe with a script that exits
  # with each status in turn and repeats the last one.
  def stub_read_probe(*statuses)
    path = File.join(@dir, 'job', 'bin', 's3-read-probe')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(File.join(@dir, 'probe-statuses'), statuses.join("\n"))
    File.write(path, <<~SH)
      #!/bin/sh
      n=$(cat "#{@dir}/probe-count" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > "#{@dir}/probe-count"
      s=$(sed -n "${n}p" "#{@dir}/probe-statuses")
      [ -n "$s" ] || s=$(tail -n 1 "#{@dir}/probe-statuses")
      echo "probe call $n exits $s"
      exit "$s"
    SH
    FileUtils.chmod(0o755, path)
  end

  def probe_count
    File.exist?(File.join(@dir, 'probe-count')) ? File.read(File.join(@dir, 'probe-count')).to_i : 0
  end

  def ready(drives = [])
    [200, JSON.generate('status' => 'ok', 'ready' => true,
                        'details' => { 'storage' => { 'ready' => true, 'unavailableDrives' => drives } })]
  end

  let(:missing_drive) { [{ 'poolIndex' => 0, 'setIndex' => 0, 'diskIndex' => 0, 'runtimeState' => 'offline' }] }
  let(:not_ready) { [503, '{"status":"degraded","ready":false}'] }

  describe 'bin/post-start' do
    def post_start(index, properties = props, addresses = addrs)
      render('bin/post-start', properties, node(addresses, index), peers(addresses), 'post-start')
    end

    it 'passes on liveness alone when no other peer is ready' do
      stub_read_probe(1)
      respond('*/health' => [[200, '{}']], '*/health/ready' => [not_ready])
      out, err, status = run(post_start(0))
      expect(status.exitstatus).to eq(0), err
      expect(out).to include('passing on liveness alone')
      expect(probe_count).to eq(0)
    end

    it 'waits until every node sees every drive and a read succeeds' do
      stub_read_probe(1, 0)
      respond(
        '*/health' => [[200, '{}']],
        '10.0.0.2:9000/health/ready' => [not_ready, ready(missing_drive), ready],
        '10.0.0.1:9000/health/ready' => [ready(missing_drive), ready(missing_drive), ready(missing_drive), ready],
        '10.0.0.3:9000/health/ready' => [ready]
      )
      out, err, status = run(post_start(1))
      expect(status.exitstatus).to eq(0), err
      expect(out).to include('10.0.0.2 is not ready')
      expect(out).to include('unavailable drives reported by')
      expect(out).to include('serving after')
      # one failed read, one read while a drive is still missing, then
      # three passes in a row
      expect(probe_count).to eq(5)
    end

    it 'restarts the settle count when a check fails between passes' do
      stub_read_probe(0, 1, 0)
      respond('*/health' => [[200, '{}']], '*/health/ready' => [ready])
      _, err, status = run(post_start(0))
      expect(status.exitstatus).to eq(0), err
      expect(probe_count).to eq(5)
    end

    it 'tolerates a peer that is down, because its drives cannot be visible' do
      stub_read_probe(0)
      respond(
        '10.0.0.1:9000/health' => [[200, '{}']],
        '10.0.0.2:9000/health' => [[200, '{}']],
        '10.0.0.3:9000/health' => [[0, '']],
        '10.0.0.1:9000/health/ready' => [ready(missing_drive)],
        '10.0.0.2:9000/health/ready' => [ready(missing_drive)]
      )
      out, err, status = run(post_start(0))
      expect(status.exitstatus).to eq(0), err
      expect(out).to include('peers 10.0.0.3 are down')
    end

    it 'passes with a warning when reads succeed but a drive stays unavailable past the timeout' do
      stub_read_probe(0)
      properties = props.merge('rustfs' => props['rustfs'].merge('post_start' => { 'ready_timeout_secs' => 0 }))
      respond('*/health' => [[200, '{}']], '10.0.0.1:9000/health/ready' => [ready(missing_drive)],
              '*/health/ready' => [ready])
      _, err, status = run(post_start(1, properties))
      expect(status.exitstatus).to eq(0), err
      expect(err).to include('WARNING: this node serves reads')
      expect(err).to include('unavailable drives reported by 10.0.0.1')
    end

    it 'fails once the timeout passes while reads still fail' do
      stub_read_probe(1)
      properties = props.merge('rustfs' => props['rustfs'].merge('post_start' => { 'ready_timeout_secs' => 0 }))
      respond('*/health' => [[200, '{}']], '10.0.0.1:9000/health/ready' => [ready(missing_drive)],
              '*/health/ready' => [ready])
      out, err, status = run(post_start(1, properties))
      expect(status.exitstatus).to eq(1)
      expect(out + err).to include('did not serve reads within 0s')
    end

    it 'fails at once when the read probe says waiting cannot help' do
      stub_read_probe(2)
      respond('*/health' => [[200, '{}']], '*/health/ready' => [ready])
      _, err, status = run(post_start(0))
      expect(status.exitstatus).to eq(1)
      expect(err).to include('probe call 1 exits 2')
      expect(probe_count).to eq(1)
    end

    it 'treats a readiness body without drive detail as seeing every drive' do
      stub_read_probe(0)
      respond('*/health' => [[200, '{}']], '*/health/ready' => [[200, '{"status":"ok","ready":true}']])
      _, err, status = run(post_start(2))
      expect(status.exitstatus).to eq(0), err
    end

    it 'waits for its own readiness and a read on a single node' do
      stub_read_probe(0)
      respond('127.0.0.1:9000/health' => [[200, '{}']], '127.0.0.1:9000/health/ready' => [not_ready, ready])
      out, err, status = run(post_start(0, props, ['10.0.0.1']))
      expect(status.exitstatus).to eq(0), err
      expect(out).to include('single node')
      expect(out).to include('127.0.0.1 is not ready')
      expect(probe_count).to eq(3)
    end
  end

  describe 'bin/drain' do
    def drain(index)
      FileUtils.mkdir_p(File.join(@dir, 'log'))
      render('bin/drain', props, node(addrs, index), peers(addrs), 'drain')
    end

    it 'asks BOSH to call again while a peer lists an unavailable drive' do
      respond('10.0.0.1:9000/health/ready' => [ready], '10.0.0.2:9000/health/ready' => [ready(missing_drive)],
              '10.0.0.3:9000/health/ready' => [ready])
      out, _, status = run(drain(0))
      expect(status.exitstatus).to eq(0)
      expect(out).to eq("-5\n")
      expect(File.read(File.join(@dir, 'log', 'drain.log'))).to include('10.0.0.2(drives)')
    end

    it 'lets the stop go ahead once every peer is ready and sees every drive' do
      respond('*/health/ready' => [ready])
      out, _, status = run(drain(0))
      expect(status.exitstatus).to eq(0)
      expect(out).to eq("0\n")
    end
  end

  describe 'bin/s3-read-probe' do
    let(:probe) { render('bin/s3-read-probe', props, node(addrs, 0), peers(addrs), 's3-read-probe') }

    def list_buckets(*names)
      body = names.map { |n| "<Bucket><Name>#{n}</Name><CreationDate>2026-10-21T00:00:00Z</CreationDate></Bucket>" }.join
      [200, "<ListAllMyBucketsResult><Owner><ID>x</ID><DisplayName>x</DisplayName></Owner><Buckets>#{body}</Buckets></ListAllMyBucketsResult>"]
    end

    def list_objects(bucket, *keys)
      body = keys.map { |k| "<Contents><Key>#{k}</Key><Size>3</Size></Contents>" }.join
      [200, "<ListBucketResult><Name>#{bucket}</Name><KeyCount>#{keys.length}</KeyCount>#{body}</ListBucketResult>"]
    end

    def hmac(key, data)
      OpenSSL::HMAC.digest('sha256', key, data)
    end

    # expected_signature recomputes AWS Signature Version 4 for one call
    # that the fake recorded.
    def expected_signature(call)
      headers = call.each_cons(2).select { |a, _| a == '-H' }.map(&:last)
      date = headers.find { |h| h.start_with?('x-amz-date: ') }.split(': ', 2).last
      host = headers.find { |h| h.start_with?('Host: ') }.split(': ', 2).last
      url = call.find { |a| a.start_with?('http') }
      path, query = url.sub(%r{\Ahttps?://[^/]+}, '').split('?', 2)
      empty = Digest::SHA256.hexdigest('')
      canonical = ['GET', path, query.to_s,
                   "host:#{host}\nx-amz-content-sha256:#{empty}\nx-amz-date:#{date}\n",
                   'host;x-amz-content-sha256;x-amz-date', empty].join("\n")
      scope = "#{date[0, 8]}/us-east-1/s3/aws4_request"
      sts = ['AWS4-HMAC-SHA256', date, scope, Digest::SHA256.hexdigest(canonical)].join("\n")
      key = hmac("AWS4#{secret}", date[0, 8])
      key = hmac(key, 'us-east-1')
      key = hmac(key, 's3')
      key = hmac(key, 'aws4_request')
      OpenSSL::HMAC.hexdigest('sha256', key, sts)
    end

    def signature_of(call)
      auth = call.each_cons(2).select { |a, _| a == '-H' }.map(&:last).find { |h| h.start_with?('Authorization: ') }
      auth[/Signature=([0-9a-f]+)/, 1]
    end

    it 'lists, lists one object, and reads its first byte with valid signatures' do
      respond('10.0.0.1:9000/' => [list_buckets('alpha', 'beta')],
              '10.0.0.1:9000/alpha' => [list_objects('alpha', 'dir/a b&amp;c.txt')],
              '10.0.0.1:9000/alpha/dir/a%20b%26c.txt' => [[206, 'x']])
      out, err, status = run(probe, '10.0.0.1')
      expect(status.exitstatus).to eq(0), out + err
      expect(out).to include('served ListBuckets, ListObjectsV2, and GetObject on alpha (206)')
      expect(calls.length).to eq(3)
      expect(calls[1].last).to eq('https://10.0.0.1:9000/alpha?list-type=2&max-keys=1').or eq('http://10.0.0.1:9000/alpha?list-type=2&max-keys=1')
      expect(calls[2]).to include('Range: bytes=0-0')
      calls.each { |c| expect(signature_of(c)).to eq(expected_signature(c)) }
    end

    it 'never puts the secret key on a command line' do
      respond('10.0.0.1:9000/' => [list_buckets])
      run(probe, '10.0.0.1')
      expect(calls.flatten.join(' ')).not_to include(secret)
      expect(File.read(probe)).not_to include('-macopt')
    end

    it 'passes on the listing alone when there is no bucket' do
      respond('10.0.0.1:9000/' => [list_buckets])
      out, _, status = run(probe, '10.0.0.1')
      expect(status.exitstatus).to eq(0)
      expect(out).to include('there is no bucket to read')
    end

    it 'counts a 4xx on the object as served' do
      respond('10.0.0.1:9000/' => [list_buckets('alpha')],
              '10.0.0.1:9000/alpha' => [list_objects('alpha', 'k')],
              '10.0.0.1:9000/alpha/k' => [[400, '']])
      _, _, status = run(probe, '10.0.0.1')
      expect(status.exitstatus).to eq(0)
    end

    it 'reports 503 on the object as not serving yet' do
      respond('10.0.0.1:9000/' => [list_buckets('alpha')],
              '10.0.0.1:9000/alpha' => [list_objects('alpha', 'k')],
              '10.0.0.1:9000/alpha/k' => [[503, '']])
      out, _, status = run(probe, '10.0.0.1')
      expect(status.exitstatus).to eq(1)
      expect(out).to include('GetObject on alpha answered 503')
    end

    it 'reports a refused connection as not serving yet' do
      respond('10.0.0.1:9000/' => [[0, '']])
      out, _, status = run(probe, '10.0.0.1')
      expect(status.exitstatus).to eq(1)
      expect(out).to include('ListBuckets answered 000')
    end

    it 'gives up when the credentials are refused' do
      respond('10.0.0.1:9000/' => [[403, '<Error><Code>AccessDenied</Code></Error>']])
      out, _, status = run(probe, '10.0.0.1')
      expect(status.exitstatus).to eq(2)
      expect(out).to include('root credentials do not match')
    end
  end
end
