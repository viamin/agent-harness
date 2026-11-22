# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "optparse"
require "rubygems/package"
require "uri"

module AgentHarness
  module ReleaseVerification
    class Error < StandardError; end
    class AuthenticationError < Error; end
    class TransportError < Error; end
    class ApiCompatibilityError < Error; end
    class ChecksumMismatch < Error; end
    class PropagationPending < Error; end
    class InvalidArtifact < Error; end

    Artifact = Data.define(:name, :version, :sha256) do
      def initialize(name:, version:, sha256:)
        raise InvalidArtifact, "invalid gem name" unless name.match?(/\A[a-zA-Z0-9_-]+\z/)
        raise InvalidArtifact, "invalid gem version" unless version.match?(/\A[0-9a-zA-Z.-]+\z/)
        raise InvalidArtifact, "invalid SHA256" unless sha256.match?(/\A[0-9a-f]{64}\z/)

        super
      end

      def self.load(path)
        spec = Gem::Package.new(path).spec
        new(name: spec.name, version: spec.version.to_s, sha256: Digest::SHA256.file(path).hexdigest)
      end
    end

    class HttpClient
      def get(uri)
        Net::HTTP.get_response(uri)
      rescue IOError, SocketError, SystemCallError, Timeout::Error => e
        raise TransportError, "RubyGems.org transport failure: #{e.class}: #{e.message}"
      end
    end

    class Verifier
      API_ROOT = "https://rubygems.org/api/v2/rubygems"

      def initialize(client: HttpClient.new, sleeper: Kernel.method(:sleep), api_root: API_ROOT)
        @client = client
        @sleeper = sleeper
        @api_root = api_root
      end

      def verify(artifact, attempts:, interval:)
        attempts.times do |index|
          response = @client.get(version_uri(artifact))
          return verify_response(response, artifact) unless response.code.to_i == 404
          @sleeper.call(interval) if index + 1 < attempts
        end

        raise PropagationPending,
          "#{artifact.name} #{artifact.version} is not visible through the RubyGems.org public API after #{attempts} checks; publication may still be propagating"
      end

      private

      def version_uri(artifact)
        URI("#{@api_root}/#{artifact.name}/versions/#{artifact.version}.json")
      end

      def verify_response(response, artifact)
        status = response.code.to_i
        raise AuthenticationError, "RubyGems.org API rejected verification (HTTP #{status})" if [401, 403].include?(status)
        raise TransportError, "RubyGems.org API transport failure (HTTP #{status})" unless status.between?(200, 299)

        metadata = JSON.parse(response.body)
        remote_sha = metadata.fetch("sha")
        unless metadata["version"] == artifact.version && remote_sha.match?(/\A[0-9a-f]{64}\z/)
          raise ApiCompatibilityError, "RubyGems.org version response does not match the supported public API schema"
        end
        if remote_sha != artifact.sha256
          raise ChecksumMismatch,
            "#{artifact.name} #{artifact.version} is already published with SHA256 #{remote_sha}, not local SHA256 #{artifact.sha256}"
        end

        "Verified published #{artifact.name} #{artifact.version} (SHA256 #{remote_sha})"
      rescue JSON::ParserError, KeyError, TypeError
        raise ApiCompatibilityError, "RubyGems.org version response does not match the supported public API schema"
      end
    end

    class CLI
      def self.run(argv, out: $stdout, err: $stderr, verifier: Verifier.new)
        options = {attempts: 30, interval: 10}
        parser = OptionParser.new do |flags|
          flags.on("--attempts N", Integer) { |value| options[:attempts] = value }
          flags.on("--interval SECONDS", Float) { |value| options[:interval] = value }
          flags.on("--name NAME") { |value| options[:name] = value }
          flags.on("--version VERSION") { |value| options[:version] = value }
          flags.on("--sha256 SHA256") { |value| options[:sha256] = value }
        end
        parser.parse!(argv)
        raise OptionParser::InvalidArgument, "attempts must be positive" unless options[:attempts].positive?

        artifact = artifact_from(argv, options)
        out.puts verifier.verify(artifact, **options.slice(:attempts, :interval))
        0
      rescue PropagationPending => e
        err.puts e.message
        2
      rescue Error, OptionParser::ParseError => e
        err.puts "Release verification failed: #{e.message}"
        1
      end

      def self.artifact_from(argv, options)
        return Artifact.load(argv.first) if argv.one? && !options.values_at(:name, :version, :sha256).any?
        if argv.empty? && options.values_at(:name, :version, :sha256).all?
          return Artifact.new(**options.slice(:name, :version, :sha256))
        end

        raise OptionParser::MissingArgument, "provide one gem artifact or --name, --version, and --sha256"
      end
      private_class_method :artifact_from
    end
  end
end

exit AgentHarness::ReleaseVerification::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
