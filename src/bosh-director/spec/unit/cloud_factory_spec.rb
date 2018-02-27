require 'spec_helper'

module Bosh::Director
  describe CloudFactory do
    subject(:cloud_factory) { described_class.new(azs, parsed_cpi_config) }
    let(:default_cloud) { instance_double(Bosh::Clouds::ExternalCpi) }
    let(:parsed_cpi_config) { CpiConfig::ParsedCpiConfig.new(cpis) }
    let(:cpis) { [] }
    let(:logger) { double(:logger, debug: nil) }
    let(:azs) { { 'some-az' => az } }
    let(:az) { instance_double(DeploymentPlan::AvailabilityZone, name: 'some-az') }

    before do
      allow(Bosh::Director::Config).to receive(:uuid).and_return('snoopy-uuid')
      allow(Bosh::Director::Config).to receive(:cloud_options).and_return({'provider' => {'path' => '/path/to/cpi'}})
      allow(Bosh::Clouds::ExternalCpi).to receive(:new).and_return(default_cloud)
    end

    context 'factory methods' do
      let(:cpi_config) { instance_double(Models::Config) }
      let(:cloud_config) { Models::Config.make(:cloud, content: '--- {"key": "value"}') }
      let(:deployment) { instance_double(Models::Deployment) }
      let(:cpi_manifest_parser) { instance_double(CpiConfig::CpiManifestParser) }
      let(:cloud_manifest_parser) { instance_double(DeploymentPlan::CloudManifestParser) }
      let(:planner) { instance_double(DeploymentPlan::CloudPlanner) }

      before do
        allow(deployment).to receive(:cloud_configs).and_return([cloud_config])
        allow(deployment).to receive(:name).and_return('happy')
        allow(Api::CloudConfigManager).to receive(:interpolated_manifest).with([cloud_config], 'happy').and_return({})
        allow(CpiConfig::CpiManifestParser).to receive(:new).and_return(cpi_manifest_parser)
        allow(cpi_manifest_parser).to receive(:merge_configs).and_return(parsed_cpi_config)
        allow(cpi_manifest_parser).to receive(:parse).and_return(parsed_cpi_config)
        allow(cpi_config).to receive(:raw_manifest).and_return({})
        allow(DeploymentPlan::CloudManifestParser).to receive(:new).and_return(cloud_manifest_parser)
        allow(cloud_manifest_parser).to receive(:parse).and_return(planner)
        allow(cloud_manifest_parser).to receive(:parse_availability_zones).and_return([az])
      end

      describe '.create_from_deployment' do
        it 'constructs a cloud factory with all its dependencies from a deployment' do
          expect(described_class).to receive(:new).with(azs, parsed_cpi_config)
          described_class.create_from_deployment(deployment, [cpi_config])
        end

        it 'constructs a cloud factory without planner if no deployment is given' do
          expect(described_class).to receive(:new).with(nil, parsed_cpi_config)
          deployment = nil
          described_class.create_from_deployment(deployment, [cpi_config])
        end

        it 'constructs a cloud factory without parsed cpis if no cpi config is used' do
          expect(described_class).to receive(:new).with(azs, nil)
          described_class.create_from_deployment(deployment, nil)
        end

        context 'when no cloud config is provided' do
          let(:cloud_config) { Models::Config.make(:cloud, content: '--- {}') }

          it 'constructs a cloud factory without planner' do
            expect(described_class).to receive(:new).with(nil, parsed_cpi_config)
            described_class.create_from_deployment(deployment, [cpi_config])
          end
        end
      end

      describe '.create_with_latest_configs' do
        before do
          allow(Bosh::Director::Models::Config).to receive(:latest_set).with('cpi').and_return([cpi_config])
          allow(Bosh::Director::Models::Config).to receive(:latest_set).with('cloud').and_return([cloud_config])
        end

        it 'constructs a cloud factory with all its dependencies from a deployment' do
          expect(described_class).to receive(:new).with(azs, parsed_cpi_config)
          described_class.create_with_latest_configs(deployment)
        end

        context 'when no deployment is given' do
          it 'constructs a cloud factory with all its dependencies without deployment' do
            expect(described_class).to receive(:new).with(azs, parsed_cpi_config).and_return({})
            expect(Api::CloudConfigManager).to receive(:interpolated_manifest).with([cloud_config], nil)

            described_class.create_with_latest_configs
          end
        end
      end
    end

    shared_examples_for 'lookup for clouds' do
      context 'when asking for the cloud of an existing AZ without cpi' do
        let(:az) { DeploymentPlan::AvailabilityZone.new('some-az', {}, nil) }

        it 'returns the default cloud from director config' do
          cloud = cloud_factory.get_for_az('some-az')
          expect(cloud).to eq(default_cloud)
        end
      end

      context 'when an AZ references a CPI that does not exist anymore' do
        let(:az) { DeploymentPlan::AvailabilityZone.new('some-az', {}, 'not-existing-cpi') }

        it 'raises an error' do
          expect do
            cloud_factory.get_for_az('some-az')
          end.to raise_error(
            "Failed to load CPI for AZ 'some-az': CPI 'not-existing-cpi' not found in cpi-config#{config_error_hint}",
          )
        end
      end

      it 'raises if asking for a cpi that is not defined in a cpi config' do
        expect do
          cloud_factory.get('name-notexisting')
        end.to raise_error(RuntimeError, "CPI 'name-notexisting' not found in cpi-config#{config_error_hint}")
      end

      it 'returns director default if asking for cpi with empty name' do
        expect(cloud_factory.get('')).to eq(default_cloud)
      end

      it 'returns default cloud if asking for a nil cpi' do
        expect(cloud_factory.get(nil)).to eq(default_cloud)
      end

      it 'returns the default cloud from director config when asking for the cloud of a nil AZ' do
        cloud = cloud_factory.get_for_az(nil)
        expect(cloud).to eq(default_cloud)
      end
    end

    context 'when not using cpi config' do
      let(:config_error_hint) { ' (because cpi-config is not set)' }
      let(:parsed_cpi_config) { nil }

      before do
        expect(cloud_factory.uses_cpi_config?).to eq(false)
      end

      describe '#get_cpi_aliases' do
        it 'returns the empty cpi' do
          expect(cloud_factory.get_cpi_aliases('')).to eq([''])
        end
      end

      describe '#all_names' do
        it 'returns the default cpi' do
          expect(cloud_factory.all_names).to eq([''])
        end
      end

      it_behaves_like 'lookup for clouds'
    end

    context 'when using cpi config' do
      let(:config_error_hint) { '' }
      let(:az) { DeploymentPlan::AvailabilityZone.new('some-az', {}, cpis[0].name) }

      let(:cpis) do
        [
          CpiConfig::Cpi.new('name1', 'type1', nil, { 'prop1' => 'val1' }, {}),
          CpiConfig::Cpi.new('name2', 'type2', nil, { 'prop2' => 'val2' }, {}),
          CpiConfig::Cpi.new('name3', 'type3', nil, { 'prop3' => 'val3' }, {}),
        ]
      end

      let(:clouds) do
        [
          instance_double(Bosh::Cloud),
          instance_double(Bosh::Cloud),
          instance_double(Bosh::Cloud),
        ]
      end

      before do
        expect(cloud_factory.uses_cpi_config?).to be_truthy
        allow(Bosh::Clouds::ExternalCpi).to receive(:new).with(cpis[0].exec_path, Config.uuid, cpis[0].properties).and_return(clouds[0])
        allow(Bosh::Clouds::ExternalCpi).to receive(:new).with(cpis[1].exec_path, Config.uuid, cpis[1].properties).and_return(clouds[1])
        allow(Bosh::Clouds::ExternalCpi).to receive(:new).with(cpis[2].exec_path, Config.uuid, cpis[2].properties).and_return(clouds[2])
      end

      it 'returns the cloud from cpi config when asking for a AZ with this cpi' do
        expect(Bosh::Clouds::ExternalCpi).to receive(:new).with(cpis[0].exec_path, Config.uuid, cpis[0].properties).and_return(clouds[0])

        cloud = cloud_factory.get_for_az('some-az')
        expect(cloud).to eq(clouds[0])
      end

      it 'returns the cpi if asking for a given existing cpi' do
        expect(Bosh::Clouds::ExternalCpi).to receive(:new).with(cpis[1].exec_path, Config.uuid, cpis[1].properties).and_return(clouds[1])
        cloud = cloud_factory.get('name2')
        expect(cloud).to eq(clouds[1])
      end

      describe '#all_names' do
        it 'returns only the cpi-config cpis' do
          expect(cloud_factory.all_names).to eq(%w[name1 name2 name3])
        end
      end

      describe '#get_name_for_az' do
        it 'returns a cpi name when asking for an existing AZ' do
          cpi = cloud_factory.get_name_for_az('some-az')
          expect(cpi).to eq('name1')
        end
      end

      it_behaves_like 'lookup for clouds'
    end

    describe '#get_name_for_az' do
      it 'returns the default cpi name from director config when asking for the cloud of a nil AZ' do
        expect(cloud_factory.get_name_for_az(nil)).to eq('')
      end

      it 'returns the default cpi name from director config when asking for the cloud of an empty AZ' do
        expect(cloud_factory.get_name_for_az('')).to eq('')
      end

      context 'when asking for a non-existing AZ' do
        let(:az) { nil }

        it 'raises error' do
          expect do
            cloud_factory.get_name_for_az('some-az')
          end.to raise_error "AZ 'some-az' not found in cloud config"
        end
      end

      context 'when asking for the cloud of an existing AZ without cpi' do
        let(:az) { DeploymentPlan::AvailabilityZone.new('some-az', {}, nil) }

        it 'returns the default cloud from director config ' do
          expect(cloud_factory.get_name_for_az('some-az')).to eq('')
        end
      end

      context 'without azs' do
        let(:azs) { nil }

        it 'raises an error if lookup of an AZ is needed' do
          expect do
            cloud_factory.get_name_for_az('some-az')
          end.to raise_error 'AZs must be given to lookup cpis from AZ'
        end
      end
    end

    describe '#get_cpi_aliases' do
      let(:cpis) { [CpiConfig::Cpi.new('name1', 'type1', nil, { 'prop1' => 'val1' }, migrated_from)] }
      let(:migrated_from) { [{ 'name' => 'some-cpi' }, { 'name' => 'another-cpi' }] }

      it 'returns the migrated_from names for the given cpi with the official name first' do
        expect(cloud_factory.get_cpi_aliases('name1')).to contain_exactly('name1', 'some-cpi', 'another-cpi')
      end
    end

    describe '.parse_cpi_configs' do
      let(:cpi_config1) { Bosh::Spec::NewDeployments.single_cpi_config('cpi-name1') }
      let(:cpi_config2) { Bosh::Spec::NewDeployments.single_cpi_config('cpi-name2') }
      let(:cpi_config3) { Bosh::Spec::NewDeployments.single_cpi_config('cpi-name3') }
      let(:cpi1) { Bosh::Director::Models::Config.make(type: 'cpi', name: 'cpi1', content: YAML.dump(cpi_config1)) }
      let(:cpi2) { Bosh::Director::Models::Config.make(type: 'cpi', name: 'cpi2', content: YAML.dump(cpi_config2)) }
      let(:cpi3) { Bosh::Director::Models::Config.make(type: 'cpi', name: 'cpi3', content: YAML.dump(cpi_config3)) }

      it 'returns all known cpis' do
        parsed_cpis = CloudFactory.parse_cpi_configs([cpi1, cpi2, cpi3])

        expect(parsed_cpis.cpis.size).to eq(3)
        expect(parsed_cpis.cpis.map(&:name)).to match_array(['cpi-name1', 'cpi-name2', 'cpi-name3'])
      end

      context 'when no cpis are known' do
        it 'returns nil' do
          expect(CloudFactory.parse_cpi_configs(nil)).to be(nil)
          expect(CloudFactory.parse_cpi_configs([])).to be(nil)
        end
      end
    end

    describe '#get_default_cloud' do
      it "returns the director's default cloud" do
        expect(Bosh::Clouds::ExternalCpi).to receive(:new).with('/path/to/cpi', 'snoopy-uuid').and_return(default_cloud)
        expect(cloud_factory.get_default_cloud).to eq(default_cloud)
      end

      it "returns a new instance of the director's default cloud for each call" do
        expect(Bosh::Clouds::ExternalCpi).to receive(:new).twice.and_return(default_cloud, instance_double(Bosh::Clouds::ExternalCpi))

        cloud_1 = cloud_factory.get_default_cloud
        cloud_2 = cloud_factory.get_default_cloud

        expect(cloud_1).to_not equal(cloud_2)
      end
    end
  end
end
