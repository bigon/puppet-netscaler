# frozen_string_literal: true

Puppet::Type.newtype(:nsconfig_save) do
  @doc = <<~EOS
    Saves the running configuration of the NetScaler (NITRO `nsconfig`
    `save`) at the end of the device's run, when the run changed something
    and nothing failed. Declare it once in the device's catalog:

        nsconfig_save { 'running': }

    It subscribes to every `nitro_*` and `netscaler_*` resource of the
    catalog: Puppet refreshes it, and so saves, only when one of them
    changed, and skips it when one of them failed, so the saved
    configuration stays the last one applied without errors. In noop mode
    nothing is saved. A failed save fails this resource. Without it, the
    configuration is never saved.

    Changes that were not saved (a failed save, or a failed resource in the
    same run) are saved only by the next run that changes something.

    Don't order it against those resources with `->`, `require`, `before`,
    or a `notify`/`subscribe` going from it to them: that would replace the
    subscription, and the run refuses it. `~>` towards it is fine, and
    unneeded. The run also refuses a second `nsconfig_save`.
  EOS

  apply_to_device

  newparam(:name, namevar: true) do
    desc 'Any name: one resource per device is enough.'
  end

  def self.managed?(resource)
    resource.type.to_s.start_with?('nitro_', 'netscaler_')
  end

  autosubscribe(:nsconfig_save) do
    catalog.resources.select { |r| self.class.managed?(r) }
  end

  # Nothing to list or purge
  def self.instances
    []
  end

  # An explicit edge between this resource and a managed one, other than a
  # refresh towards this one, takes the place of the subscription (Puppet
  # drops an automatic relationship that an explicit one contradicts): that
  # change would not be saved
  def pre_run_check
    others = catalog.resources.select { |r| r.is_a?(self.class) && !r.equal?(self) }
    raise Puppet::Error, "#{ref} must be the only nsconfig_save of the catalog, found #{others.map(&:ref).join(', ')}" unless others.empty?

    points = ->(refs, target) { Array(refs).any? { |ref| ref.to_s == target } }
    ordered = catalog.resources.select do |r|
      next false unless self.class.managed?(r)

      %i[before require subscribe].any? { |p| points.call(r[p], ref) } ||
        %i[before require notify].any? { |p| points.call(self[p], r.ref) }
    end
    return if ordered.empty?

    raise Puppet::Error, "#{ref} must not be ordered with ->, require, before, or notify/subscribe towards them, against " \
                         "#{ordered.map(&:ref).join(', ')}: use ~> or nothing, otherwise their changes are not saved"
  end

  def refresh
    device = Puppet::Util::NetworkDevice.current
    raise Puppet::Error, "#{ref} only works with puppet device on a NetScaler" unless device.respond_to?(:transport) && device.transport.respond_to?(:save)

    device.transport.save
  end
end
