# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

*** Settings ***
Documentation       Smoketest ozone cluster startup
Library             OperatingSystem
Library             Collections
Resource            ../commonlib.robot
Resource            ../ozone-lib/shell.robot

Test Timeout        20 minutes

*** Variables ***
${SECURITY_ENABLED}                 false
${HOST}                             datanode1
${VOLUME}                           volume1
${BUCKET}                           bucket1
${SIZE}                             104857600


** Keywords ***
Prepare For Tests
    Execute             dd if=/dev/urandom of=/tmp/100mb bs=1048576 count=100
    Run Keyword if      '${SECURITY_ENABLED}' == 'true'     Kinit test user    testuser    testuser.keytab
    Execute                 ozone sh volume create /${VOLUME}
    Execute                 ozone sh bucket create /${VOLUME}/${BUCKET}


Datanode In Maintenance Mode
    ${result} =             Execute                         /opt/hadoop/bin/ozone admin datanode maintenance ${HOST}
                            Should Contain                  ${result}             Entering maintenance mode on datanode
    ${result} =             Execute                         /opt/hadoop/bin/ozone admin datanode list | grep "Operational State:*"
                            Wait Until Keyword Succeeds      30sec   5sec    Should contain   ${result}   ENTERING_MAINTENANCE
                            Wait Until Keyword Succeeds      1min    10sec   Related pipelines are closed
                            Sleep                   60000ms

Related pipelines are closed
    ${result} =         Execute          /opt/hadoop/bin/ozone admin datanode list | awk -v RS= '{$1=$1}1'|grep MAINT | sed -e 's/^.*pipelines: \\(.*\\)$/\\1/' -e 's/ /\\n/'
                        Should Contain Any   ${result}   CLOSED   No\\nrelated pipelines or the node is not in Healthy state.

Datanode Recommission
    ${result} =             Execute                         /opt/hadoop/bin/ozone admin datanode recommission ${HOST}
                            Should Contain                  ${result}             Started recommissioning datanode
                            Wait Until Keyword Succeeds      1min    10sec    Datanode Recommission is Finished
                            Sleep                   300000ms

Datanode Recommission is Finished
    ${result} =             Execute                         /opt/hadoop/bin/ozone admin datanode list | grep "Operational State:*"
                            Should Not Contain   ${result}   ENTERING_MAINTENANCE

Container Balancer
    ${result} =             Execute                         /opt/hadoop/bin/ozone admin containerbalancer start -t 1 -d 100 -i 1
                            Should Contain                  ${result}             Container Balancer started successfully.
    ${result} =             Execute                         /opt/hadoop/bin/ozone admin containerbalancer status
                            Should Contain                  ${result}             ContainerBalancer is Running.
                            Wait Until Keyword Succeeds      3min    10sec    ContainerBalancer is Not Running
                            Sleep                   60000ms

ContainerBalancer is Not Running
    ${result} =         Execute          /opt/hadoop/bin/ozone admin containerbalancer status
                        Should contain   ${result}   ContainerBalancer is Not Running.

Create Multiple Keys
    [arguments]             ${NUM_KEYS}
    ${file} =    Set Variable    /tmp/100mb
    FOR     ${INDEX}        IN RANGE                ${NUM_KEYS}
            ${fileName} =           Set Variable            file-${INDEX}.txt
            ${key} =    Set Variable    /${VOLUME}/${BUCKET}/${fileName}
            LOG             ${fileName}
            Create Key    ${key}    ${file}
            Key Should Match Local File    ${key}      ${file}
    END

Datanode Usageinfo
    [arguments]             ${uuid}
    ${result} =             Execute               ozone admin datanode usageinfo --uuid=${uuid}
                            Should Contain                  ${result}             Ozone Used

Get Uuid
    ${result} =             Execute          /opt/hadoop/bin/ozone admin datanode list | awk -v RS= '{$1=$1}1'| grep ${HOST} | sed -e 's/Datanode: //'|sed -e 's/ .*$//'
    [return]          ${result}

Close All Containers
    FOR     ${INDEX}    IN RANGE    15
        ${container} =      Execute          ozone admin container list --state OPEN | jq -r 'select(.replicationConfig.replicationFactor == "THREE") | .containerID' | head -1
        EXIT FOR LOOP IF    "${container}" == ""
                            Execute          ozone admin container close "${container}"
        ${output} =         Execute          ozone admin container info "${container}"
                            Should contain   ${output}   CLOS
    END
    Wait until keyword succeeds    3min    10sec    All container is closed

All container is closed
    ${output} =         Execute          ozone admin container list
                        Should Not Contain   ${output}   OPEN

** Test Cases ***
Verify Container Balancer for RATIS containers
    Prepare For Tests

    Datanode In Maintenance Mode

    ${uuid} =                   Get Uuid
    Datanode Usageinfo          ${uuid}

    Create Multiple Keys          3

    Close All Containers

    ${output1} =    Execute    export DATANODES=$(ozone admin datanode list --json) && for datanode in $(echo "$\{DATANODES\}" | jq -r '.[].datanodeDetails.uuid'); do ozone admin datanode usageinfo --uuid=$\{datanode\} --json | jq '{(.[0].datanodeDetails.uuid) : .[0].ozoneUsed}'; done | jq -s add

    ${datanodePreviousUsedBytes}    Execute    echo '${output1}' | jq '. | to_entries | .[] | select(.key == "${uuid}") | .value'
    Should Be True    ${datanodePreviousUsedBytes} < ${SIZE}

    Datanode Recommission

    Container Balancer

    ${output2} =    Execute    export DATANODES=$(ozone admin datanode list --json) && for datanode in $(echo "$\{DATANODES\}" | jq -r '.[].datanodeDetails.uuid'); do ozone admin datanode usageinfo --uuid=$\{datanode\} --json | jq '{(.[0].datanodeDetails.uuid) : .[0].ozoneUsed}'; done | jq -s add

    ${datanodeCurrentUsedBytes}     Execute    echo '${output2}' | jq '. | to_entries | .[] | select(.key == "${uuid}") | .value'
    Should Not Be Equal As Integers     ${datanodePreviousUsedBytes}    ${datanodeCurrentUsedBytes}
    Should Be True    ${datanodeCurrentUsedBytes} < ${SIZE} * 3.5
    Should Be True    ${datanodeCurrentUsedBytes} > ${SIZE} * 3





