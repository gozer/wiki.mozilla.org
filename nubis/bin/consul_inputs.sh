#!/bin/bash
#
# This script will get outputs from cloudformation and put them into consul
#+ Stack outputs are only put in Consul if the Description starts with the word 'Consul'
#+ Output keys are placed in the Consul tree based on their descriptions second word
#+ Note that anything following the second word is ignored.
#+ for example if you had outputs with the descriptions:
#+ "Consul: config/ Server name"
#+ "Consul / Region"
#+ "Some other description"
#+ You will have a tree that looks like:
#+ /Region_Value
#+ /config/Server_Name_Value
#
# You must give a settings file, typically this is the same parameters file you use with cloudformation
#+ or set the necessary inputs as environment variables
#

NUBIS_DOMAIN='nubis.allizom.org'
REGION='us-west-2'

have-stack-name () {
    if [ -z $STACK_NAME ]; then
        echo -e "\nERROR: You must specify a stack name\n\n"
        $0 --help
        exit 1
    fi
}

get-settings () {
    if [ "${CONSUL_ENDPOINT:-0}" != "0" ]; then
        echo "Using Environment for configuration"
    elif [ -f ${SETTINGS_FILE:-0} ]; then
        PROJECT_NAME=$(jq --monochrome-output --raw-output '.[] | if .ParameterKey == "ServiceName" then .ParameterValue else empty end | @text' $SETTINGS_FILE)
        NUBIS_ENVIRONMENT=$(jq --monochrome-output --raw-output '.[] | if .ParameterKey == "Environment" then .ParameterValue else empty end | @text' $SETTINGS_FILE)
        CONSUL_ENDPOINT="ui.${REGION}.consul.${NUBIS_ENVIRONMENT}.${NUBIS_DOMAIN}"
    else
        echo "ERROR: You must either specify a json settings file or set environment variables"
        exit 1
    fi
}

get-outputs () {
    have-stack-name
    AWS="aws cloudformation describe-stacks --stack-name $STACK_NAME --query Stacks[*].Outputs"
    if [ -f ${IO_FILE:-0} ]; then
        # Output to the file
        $AWS > $IO_FILE
    else
        $AWS
    fi
}

get-route53-nameservers () {
    have-stack-name
    STACK_ID=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME --query 'StackResources[?LogicalResourceId == `Route53Stack`].PhysicalResourceId' --output text)
    # Single stack quety
#    ZONE_ID=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME --logical-resource-id  HostedZone --query StackResources[*].PhysicalResourceId --output text)
    # Nested stack query
    ZONE_ID=$(aws cloudformation describe-stack-resources --stack-name $STACK_ID --query 'StackResources[?LogicalResourceId == `HostedZone`].PhysicalResourceId' --output text)
    aws route53 get-hosted-zone --id $ZONE_ID --query DelegationSet.NameServers --output table
}

get-ec2-instance-ip () {
    have-stack-name
    STACK_ID=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME --query 'StackResources[?LogicalResourceId == `EC2Stack`].PhysicalResourceId' --output text)
    AS_GROUP=$(aws cloudformation describe-stack-resources --stack-name $STACK_ID --query 'StackResources[?LogicalResourceId == `AutoScalingGroup`].PhysicalResourceId' --output text)
    INSTANCE_ID=$(aws autoscaling describe-auto-scaling-instances --query "AutoScalingInstances[?AutoScalingGroupName == \`$AS_GROUP\`].InstanceId" --output text)
    aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[*].Instances[*].PrivateIpAddress' --output text
}

update-consul () {
    if [ ! -f ${IO_FILE:-0} ]; then
        echo "ERROR: Must pass a json file to update-consul"
        exit 1
    fi

    CONSUL="http://$CONSUL_ENDPOINT/v1/kv/$PROJECT_NAME/$NUBIS_ENVIRONMENT"
    COUNT=0
    NUM_OUTPUTS=$(jq --monochrome-output --raw-output '.[0] | length' $IO_FILE)
    while [ $COUNT -lt ${NUM_OUTPUTS:-0} ]; do
        # Test to see if the description starts with 'Consul:'
        IS_CONSUL=$(jq --monochrome-output --raw-output ".[0][$COUNT] | .Description" $IO_FILE | cut -d " " -f 1)
        if [ $IS_CONSUL == "Consul:" ]; then
            # Grab the Consul path from the second element
            CONSUL_PATH=$(jq --monochrome-output --raw-output ".[0][$COUNT] | .Description" $IO_FILE | cut -d " " -f 2)
            # If the value is simply in root '/' we need to strip it or consul will not put it (ie // becomes /)
            if [ ${CONSUL_PATH:-0} == "/" ]; then
                unset CONSUL_PATH
            fi

            KEY=$(jq --monochrome-output --raw-output ".[0][$COUNT] | .OutputKey" $IO_FILE)
            VALUE=$(jq --monochrome-output --raw-output ".[0][$COUNT] | .OutputValue" $IO_FILE)
            echo -n "$VALUE ${CONSUL_PATH}${KEY} "
            curl -s -X PUT -d $VALUE ${CONSUL}/${CONSUL_PATH}${KEY}
        fi
        COUNT=$[$COUNT+1]
    done
}

get-and-update () {
    # If we do not get an I/O file then put on in temp
    if [ ! -f ${IO_FILE:-0} ]; then
        AUTOGEN_IO=1
        IO_FILE=$(mktemp /tmp/consul_io.json.XXXXXXXX)
    fi
    get-outputs
    update-consul
    if [ ${AUTOGEN_IO:-0} == 1 ]; then
        rm $IO_FILE
    fi
}

# Grab and setup called options
while [ "$1" != "" ]; do
    case $1 in
        -v | --verbose )
            # For this simple script this will basicaly set -x
            set -x
        ;;
        -s | --settings )
            # The name of a file, in json format, to get settings from
            SETTINGS_FILE=$2
            shift
            get-settings
        ;;
        -S | --stack-name )
            # The name of the stack we are working with
            STACK_NAME=$2
            shift
        ;;
        -r | --region )
            # The name of the stack we are working with
            SREGION=$2
            shift
        ;;
        -f | --file )
            # The name of a file to write the json outputs to.
            # This works regardless of other options to the file if data is being collected from AWS
            # If you are only updating Consul, this file is the location of the JSON data
            IO_FILE=$2
            shift
        ;;
         -h | -H | --help )
            echo -en "$0\n\n"
            echo -en "Usage: $0 [options] --stack-name StackName command\n\n"
            echo -en "Commands:\n"
            echo -en "  get-and-update              Run get-outputs followed by update-consul\n"
            echo -en "  get-outputs                 Get defined outputs\n"
            echo -en "  update-consul               Put values into Consul\n"
            echo -en "  get-route53-nameservers     Get the list of Route53 nameservers\n\n"
            echo -en "Options:\n"
            echo -en "  --help        -h            Print this help information and exit\n"
            echo -en "  --settings    -s            Specify a file containing settings\n"
            echo -en "                                This file should describe your consul credentials\n"
            echo -en "                                --settings nubis/cloudformation/parameters.json\n"
            echo -en "  --stack-name  -S            Specify the name of the stack\n"
            echo -en "  --region      -r            Specify the name of the region your stack is in\n"
            echo -en "                                this optional parameter overrides the default\n"
            echo -en "  --file        -f            Specify a file for reading and writing in json format\n"
            echo -en "                                If get-outputs will write to file (Optional) or print to sdtout\n"
            echo -en "                                If update-consul will read from file\n"
            echo -en "  --verbose     -v            Turn on verbosity\n"
            echo -en "                                Basically set -x\n\n"
            exit 0
        ;;
        get-outputs | get-out )
            # This simply grabs everything defined as an output and dumps it.
            # See --file if you wish to save to a file without a redirect
            get-outputs
            GOT_COMMAND=1
        ;;
        update-consul )
            # Just pushes data to Consul, requires --file or stdin
            update-consul
            GOT_COMMAND=1
        ;;
        get-route53-nameservers | get-ns)
            # Collect the Route53 ZoneId from AWS
            get-route53-nameservers
            GOT_COMMAND=1
        ;;
        get-ec2-instance-ip | get-ip)
            # Collect the ec2 instance ip from AWS
            get-ec2-instance-ip
            GOT_COMMAND=1
        ;;
        io | get-and-update )
            # Get the outputs from AWS and put them in Consul
            get-and-update
            GOT_COMMAND=1
        ;;
    esac
    shift
done

# If we did not get a valid command print the help message
if [ ${GOT_COMMAND:-0} == 0 ]; then
    $0 --help
fi
