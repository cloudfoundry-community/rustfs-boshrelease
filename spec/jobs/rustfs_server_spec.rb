require 'rspec'
require 'yaml'
require 'bosh/template/test'

FAKE_CERT = "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n".freeze
FAKE_KEY  = "-----BEGIN PRIVATE KEY-----\nMIIBfake\n-----END PRIVATE KEY-----\n".freeze
FAKE_CA   = "-----BEGIN CERTIFICATE-----\nMIIBfakeca\n-----END CERTIFICATE-----\n".freeze

describe 'rustfs release templates' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '../..')) }

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

  let(:v4)  { %w[10.0.0.1 10.0.0.2 10.0.0.3] }
  let(:v6)  { %w[fd00::1 fd00::2 fd00::3] }
  let(:creds) { { 'access_key' => 'ak', 'secret_key' => 'sk' } }
  let(:tls_props) do
    { 'rustfs' => creds.merge('tls' => { 'certificate' => FAKE_CERT, 'key' => FAKE_KEY, 'ca' => FAKE_CA }) }
  end
  let(:plain_props) { { 'rustfs' => creds } }

  describe 'rustfs-server' do
    let(:job) { release.job('rustfs-server') }

    describe 'config/bpm.yml' do
      let(:template) { job.template('config/bpm.yml') }

      def env(props, addrs, idx = 0)
        YAML.safe_load(template.render(props, spec: node(addrs, idx), consumes: peers(addrs)))['processes'][0]['env']
      end

      def volumes(props, addrs)
        YAML.safe_load(template.render(props, spec: node(addrs, 0), consumes: peers(addrs)))['processes'][0]['args'][1]
      end

      it 'lists every peer over https in a TLS cluster' do
        expect(volumes(tls_props, v4)).to eq(
          'https://10.0.0.1:9000/var/vcap/store/rustfs-server/data0 ' \
          'https://10.0.0.2:9000/var/vcap/store/rustfs-server/data0 ' \
          'https://10.0.0.3:9000/var/vcap/store/rustfs-server/data0'
        )
      end

      it 'brackets IPv6 peers and binds the IPv6 wildcard' do
        expect(volumes(tls_props, v6)).to start_with('https://[fd00::1]:9000/var/vcap/store/rustfs-server/data0 ')
        expect(env(tls_props, v6)['RUSTFS_ADDRESS']).to eq('[::]:9000')
        expect(env(tls_props, v6)['RUSTFS_CONSOLE_ADDRESS']).to eq('[::]:9001')
      end

      it 'binds the IPv4 wildcard for IPv4 peers' do
        expect(env(tls_props, v4)['RUSTFS_ADDRESS']).to eq('0.0.0.0:9000')
      end

      it 'uses a local path for a single node' do
        expect(volumes(plain_props, ['10.0.0.1'])).to eq('/var/vcap/store/rustfs-server/data0')
      end

      it 'refuses a certificate without a key' do
        props = { 'rustfs' => creds.merge('tls' => { 'certificate' => FAKE_CERT }) }
        expect { env(props, ['10.0.0.1']) }.to raise_error(/rustfs.tls.certificate is set but rustfs.tls.key is not/)
      end

      it 'refuses a key without a certificate' do
        props = { 'rustfs' => creds.merge('tls' => { 'key' => FAKE_KEY }) }
        expect { env(props, ['10.0.0.1']) }.to raise_error(/rustfs.tls.key is set but rustfs.tls.certificate is not/)
      end

      it 'refuses a TLS cluster without a CA' do
        props = { 'rustfs' => creds.merge('tls' => { 'certificate' => FAKE_CERT, 'key' => FAKE_KEY }) }
        expect { env(props, v4) }.to raise_error(/rustfs.tls.ca must hold the CA certificate/)
      end

      it 'allows a single TLS node without a CA' do
        props = { 'rustfs' => creds.merge('tls' => { 'certificate' => FAKE_CERT, 'key' => FAKE_KEY }) }
        expect(env(props, ['10.0.0.1'])['RUSTFS_TLS_PATH']).to eq('/var/vcap/data/rustfs-server/tls')
      end
    end

    describe 'config/env.sh' do
      let(:template) { job.template('config/env.sh') }

      it 'brackets IPv6 peers like bpm.yml does' do
        out = template.render(tls_props, spec: node(v6, 0), consumes: peers(v6))
        expect(out).to include('export RUSTFS_VOLUMES="https://[fd00::1]:9000/var/vcap/store/rustfs-server/data0 ')
        expect(out).to include('export RUSTFS_ADDRESS="[::]:9000"')
      end
    end

    describe 'bin/post-start' do
      let(:template) { job.template('bin/post-start') }

      it 'dials its own address with the CA and lists only the other peers' do
        out = template.render(tls_props, spec: node(v4, 1), consumes: peers(v4))
        expect(out).to include('SELF="10.0.0.2"')
        expect(out).to include('PEERS=("10.0.0.1" "10.0.0.3")')
        expect(out).to include('CURL_TLS=(--cacert /var/vcap/jobs/rustfs-server/tls/ca.crt)')
        expect(out).not_to include('CURL_TLS=(-k)')
        expect(out).to include('READY_TIMEOUT=300')
      end

      it 'brackets IPv6 addresses' do
        out = template.render(tls_props, spec: node(v6, 0), consumes: peers(v6))
        expect(out).to include('SELF="[fd00::1]"')
        expect(out).to include('PEERS=("[fd00::2]" "[fd00::3]")')
      end

      it 'dials loopback and has no peers on a single node' do
        out = template.render(plain_props, spec: node(['10.0.0.1'], 0), consumes: peers(['10.0.0.1']))
        expect(out).to include('SELF="127.0.0.1"')
        expect(out).to include('PEERS=()')
        expect(out).to include('SCHEME=http')
      end

      it 'honours the timeouts' do
        props = { 'rustfs' => creds.merge('post_start' => { 'health_timeout_secs' => 30, 'ready_timeout_secs' => 45 }) }
        out = template.render(props, spec: node(v4, 0), consumes: peers(v4))
        expect(out).to include('HEALTH_TIMEOUT=30')
        expect(out).to include('READY_TIMEOUT=45')
      end
    end

    describe 'bin/drain' do
      let(:template) { job.template('bin/drain') }

      it 'waits on the other peers with the CA, bounded by the timeout' do
        out = template.render(tls_props, spec: node(v4, 2), consumes: peers(v4))
        expect(out).to include('SELF="10.0.0.3"')
        expect(out).to include('PEERS=("10.0.0.1" "10.0.0.2")')
        expect(out).to include('TIMEOUT=600')
        expect(out).to include('POLL=5')
        expect(out).to include('--cacert /var/vcap/jobs/rustfs-server/tls/ca.crt')
      end

      it 'takes a configured bound and poll interval' do
        props = { 'rustfs' => creds.merge('drain' => { 'timeout_secs' => 60, 'poll_secs' => 0 }) }
        out = template.render(props, spec: node(v4, 0), consumes: peers(v4))
        expect(out).to include('TIMEOUT=60')
        expect(out).to include('POLL=1')
      end
    end
  end

  describe 'smoke-tests' do
    let(:job) { release.job('smoke-tests') }
    let(:template) { job.template('bin/run') }
    let(:errand) { Bosh::Template::Test::InstanceSpec.new(id: 'smoke', address: '10.0.0.9', ip: '10.0.0.9') }

    it 'verifies against the CA when one is set' do
      out = template.render(tls_props, spec: errand, consumes: peers(v4))
      expect(out).to include('CURL_TLS=(--cacert /var/vcap/jobs/smoke-tests/tls/ca.crt)')
      expect(out).to include('/health/ready')
    end

    it 'falls back to -k with a warning when TLS has no CA' do
      props = { 'rustfs' => creds.merge('tls' => { 'certificate' => FAKE_CERT }) }
      out = template.render(props, spec: errand, consumes: peers(['10.0.0.1']))
      expect(out).to include('CURL_TLS=(-k)')
      expect(out).to include('SMOKE WARN')
    end

    it 'keeps the secret key out of openssl arguments' do
      out = template.render(tls_props, spec: errand, consumes: peers(v4))
      expect(out).not_to include('-macopt')
    end

    it 'brackets IPv6 peers' do
      out = template.render(tls_props, spec: errand, consumes: peers(v6))
      expect(out).to include('"[fd00::1]"')
    end
  end
end
