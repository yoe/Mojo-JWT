package Mojo::JWT;

use Mojo::Base -base;

use Mojo::JSON qw/encode_json decode_json/;
use MIME::Base64 qw/encode_base64url decode_base64url/;

has algorithm => 'HS256';
has allow_none => 0;
has claims => sub { {} };
has secret => '';

has [qw/expires not_before/];

my $re_hs = qr/^HS(\d+)$/;
my $re_rs = qr/^RS(\d+)$/;

sub decode {
  my ($self, $token, $secret) = @_;
  $self->{token} = $token;

  # reset
  $self->algorithm(undef);
  delete $self->{$_} for qw/claims expires not_before/;

  my ($hstring, $cstring, $signature) = split /\./, $jwt;
  my $header = decode_json decode_base64url($hstring);
  my $claims = decode_json decode_base64url($cstring);
  $signature = decode_base64url $signature;

  die 'Not a JWT' unless $header->{typ} eq 'JWT';
  die 'Required header field "alg" not specified'
    unless my $algo = $self->algorithm($header->{alg})->algorithm;

  # passed in secret can be a hash or code ref, store the result in the attribute
  if (defined $secret) {
    if(my $ref = ref $secret) {
      if ($ref eq 'HASH') {
        $secret = $secret->{$claims->{iss} || ''};
      } elsif ($ref eq 'CODE') {
        $secret = $self->$secret($claims);
      } else {
        die 'secret not understood';
      }
    }
    $self->secret($secret);
  } else {
    $secret = $self->secret;
  }

  # check signature
  my $payload = "$hstring.$cstring";
  if ($algo eq 'none') {
    die 'Algorithm "none" is prohibited'
      unless $self->allow_none;
  } elsif ($algo =~ $re_rs) {
    die 'Failed RS validation'
      unless $self->verify_rsa($1, $payload, $secret, $signature);
  } elsif ($algo =~ $re_hs) {
    die 'failed HS validation'
      unless $signature eq $self->sign_hmac($1, $payload, $secret);
  } else {
    die 'Unknown algorithm';
  }

  # check timing
  my $now = time;
  if (defined(my $exp = $claims->{exp})) {
    die 'JWT has expired' if $now > $exp;
    $self->expires($exp);
  }
  if (defined(my $nbf = $claims->{nbf})) {
    die 'JWT is not yet valid' if $now < $nbf;
    $self->not_before($nbf);
  }

  return $self->claims($claims)->claims;
}

sub encode {
  my $self = shift;

  my $claims = $self->claims;
  if (defined(my $exp = $self->expires))    { $claims->{exp} //= $exp }
  if (defined(my $nbf = $self->not_before)) { $claims->{nbf} //= $nbf }

  my $hstring = encode_base64url encode_json($self->header);
  my $cstring = encode_base64url encode_json($claims);
  my $payload = "$hstring.$cstring";
  my $signature;
  my $algo = $self->algorithm;
  if ($algo eq 'none') {
    $signature = '';
  } elsif ($algo =~ $re_rs) {
    $signature = $self->sign_rsa($1, $payload, $self->secret);
  } elsif ($algo =~ $re_hs) {
    $signature = $self->sign_hmac($1, $payload, $self->secret);
  } else {
    die 'Unknown algorithm';
  }

  return $self->{token} = "$payload." . encode_base64url $signature;
}

sub header { { typ => 'JWT', alg => shift->algorithm } }

sub sign_hmac {
  my ($self, $type, $payload, $secret) = @_;
  require Digest::SHA;
  my $f = Digest::SHA->can("hmac_sha$type") || die 'Unknown HMAC SHA algorithm';
  return $f->($payload, $secret);
}

sub sign_rsa {
  my ($self, $type, $payload, $private) = @_;
  require Crypt::OpenSSL::RSA;
  my $crypt = Crypt::OpenSSL::RSA->new_private_key($private);
  my $method = $crypt->can("use_sha${type}_hash") || die 'Unknown RSA hash algorithm';
  $crypt->$method;
  return $crypt->sign($payload);
}

sub token { shift->{token} }

sub verify_rsa {
  my ($self, $type, $payload, $public, $signature) = @_;
  require Crypt::OpenSSL::RSA;
  my $crypt = Crypt::OpenSSL::RSA->new_public_key($public);
  my $method = $crypt->can("use_sha${type}_hash") || die 'Unknown RSA hash algorithm';
  $crypt->$method;
  return $crypt->verify($payload, $signature);
}

1;

