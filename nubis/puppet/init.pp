# Main entry for puppet
#
# import is depricated and we should use another method for including these
#+ manifests
#

import 'apache.pp'
import 'mysql.pp'
import 'fluentd.pp'
import 'varnish.pp'
import 'nubis_configuration.pp'
import 'nubis_storage.pp'

exec { "apt-get update":
    command => "/usr/bin/apt-get update",
}

package { 'php-apc':
  ensure => '4.0.2-2build1',
  require  => Exec['apt-get update'],
}

package { 'php5-gd':
  ensure => '5.5.9+dfsg-1ubuntu4.9',
  require  => Exec['apt-get update'],
}

package { 'php5-mysql':
  ensure => '5.5.9+dfsg-1ubuntu4.9',
  require  => Exec['apt-get update'],
}

package { 'makepasswd':
  ensure => '1.10-9',
  require  => Exec['apt-get update'],
}

package { 'git':
  ensure => 'latest',
  require  => Exec['apt-get update'],
}
