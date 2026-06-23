This is a mod of the https://github.com/solmoller/eversolar-monitor.git and the tobias mod https://github.com/tobiasnorbo/eversolar-monitor.git.

Tobias included the tool to make the inverter work with 5 to 99% of its power back to the power grid. 

So most credits go to the contributers i only modded it with to my likes with the help of claude ai and use github as a backup and insperation for others

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/2fb82b27-ac32-4bf8-a8ed-2cdc3bb3e868" />

i use Home Assistant and for the legacy Domoticz to show  and comtrol my domotica.

I use a day a head to grab my energy prices from my energy provider and with this card in home assistant i can see and control it remotely

type: vertical-stack
cards:
  - type: entities
    title: Zeversolar vermogensbeheer
    entities:
      - entity: input_number.pv_power_limit
        name: Handmatige limiet
      - entity: input_boolean.zeversolar_auto_prijslimiet
        name: Auto-limiet bij negatieve prijs
      - entity: sensor.entso_current_electricity_market_price
        name: Huidige stroomprijs
      - entity: sensor.entso_next_hour_electricity_market_price
   
when prices go negative and i have to pay for every kw i send back to grid i want my inverter to slow down and hang on on what i use in standby +- 250 watt. this is checked by the hour

i use this automation in yaml

alias: "Zeversolar: Beperk teruglever bij negatieve stroomprijs"
description: >
  Als de ENTSO-E stroomprijs negatief is, zet de omvormer op 5% (minimaal
  terugleven). Bij positieve prijs weer op 99%. Controleert elk uur op :02 en
  bij HA opstart.
triggers:
  - trigger: time_pattern
    minutes: "02"
  - trigger: homeassistant
    event: start
conditions: []
variables:
  huidige_prijs: "{{ states('sensor.entso_current_electricity_market_price') | float(0) }}"
  volgend_uur_prijs: "{{ states('sensor.entso_next_hour_electricity_market_price') | float(0) }}"
actions:
  - choose:
      - conditions:
          - condition: template
            value_template: "{{ huidige_prijs < 0 }}"
        sequence:
          - action: mqtt.publish
            data:
              topic: zeversolar/SX00046011830383/power_limit/set
              payload: "5"
              qos: 1
              retain: true
          - action: notify.persistent_notification
            data:
              title: "☀️ Zeversolar: teruglever beperkt"
              message: >
                Stroomprijs is {{ huidige_prijs }} €/kWh (negatief) — omvormer
                beperkt tot 5%. Volgend uur: {{ volgend_uur_prijs }} €/kWh.
      - conditions:
          - condition: template
            value_template: "{{ huidige_prijs >= 0 }}"
        sequence:
          - action: mqtt.publish
            data:
              topic: zeversolar/SX00046011830383/power_limit/set
              payload: "99"
              qos: 1
              retain: true
mode: single

and 

- alias: "Zeversolar: Stuur PV power limit"
  description: "Publiceert de slider-waarde via MQTT naar de omvormer. Minimum i                                                                                                             s altijd 5%."
  trigger:
    - platform: state
      entity_id: input_number.pv_power_limit
  action:
    - service: mqtt.publish
      data:
        topic: "zeversolar/SX00046011830383/power_limit/set"
        payload: "{{ [states('input_number.pv_power_limit') | int, 5] | max }}"
        retain: true
and 

- alias: "Zeversolar: Sync power limit bij opstart"
  description: "Leest de huidige waarde van de omvormer en zet de slider gelijk.                                                                                                              Wacht 10 seconden zodat MQTT sensoren geladen zijn."
  trigger:
    - platform: homeassistant
      event: start
  action:
    - delay: "00:00:10"
    - service: input_number.set_value
      target:
        entity_id: input_number.pv_power_limit
      data:
        value: "{{ [states('sensor.pv_power_limit_actief') | int, 5] | max }}"


        name: Volgende uur

