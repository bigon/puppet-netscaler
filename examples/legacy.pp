# A manifest written for puppetlabs-netscaler keeps working
netscaler_server { 'server1':
  ensure  => present,
  address => '1.10.1.1',
}
netscaler_service { 'service1':
  ensure      => 'present',
  server_name => 'server1',
  port        => '80',
  protocol    => 'HTTP',
  comments    => 'This is a comment',
}
netscaler_lbvserver { 'lbvserver1':
  ensure       => 'present',
  service_type => 'HTTP',
  ip_address   => '1.10.1.2',
  port         => '8080',
  state        => true,
}
netscaler_lbvserver_service_binding { 'lbvserver1/service1':
  ensure => 'present',
  weight => '100',
}
netscaler_csvserver { 'csvserver_test1':
  ensure            => 'present',
  service_type      => 'HTTP',
  state             => true,
  ip_address        => '2.4.1.1',
  port              => '8080',
  default_lbvserver => 'lbvserver1',
}
