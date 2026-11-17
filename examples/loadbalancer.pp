# Two web servers behind an HTTP load balancer, NITRO-native types
nitro_server { 'web1':
  ensure    => present,
  ipaddress => '10.0.10.11',
}

nitro_server { 'web2':
  ensure    => present,
  ipaddress => '10.0.10.12',
}

nitro_lbmonitor { 'http-health':
  ensure      => present,
  type        => 'HTTP',
  httprequest => 'GET /health',
  respcode    => ['200'],
  interval    => 5,
}

nitro_servicegroup { 'sg_web':
  ensure      => present,
  servicetype => 'HTTP',
}

['web1', 'web2'].each |$srv| {
  nitro_servicegroup_servicegroupmember_binding { "sg_web/${srv}:80":
    ensure  => present,
    weight  => 10,
    require => [Nitro_server[$srv], Nitro_servicegroup['sg_web']],
  }
}

nitro_servicegroup_lbmonitor_binding { 'sg_web/http-health':
  ensure  => present,
  require => [Nitro_servicegroup['sg_web'], Nitro_lbmonitor['http-health']],
}

nitro_lbvserver { 'vs_web':
  ensure      => present,
  servicetype => 'HTTP',
  ipv46       => '192.0.2.10',
  port        => 80,
  lbmethod    => 'LEASTCONNECTION',
  state       => 'ENABLED',
}

nitro_lbvserver_servicegroup_binding { 'vs_web/sg_web':
  ensure  => present,
  require => [Nitro_lbvserver['vs_web'], Nitro_servicegroup['sg_web']],
}
