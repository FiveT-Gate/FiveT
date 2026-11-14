import Foundation

/// Windscribe's server list as of 2026-11-13, one country per line: `CODE|Country|Continent|City,City`.
/// Windscribe Max uses it when the CLI lists nothing and no fresher list was downloaded
/// (Update list in the Scan tab); it is only names, nothing of Windscribe's program.
enum WindscribeSnapshot {
    static let text = """
KE|Kenya|Africa|Nairobi
NG|Nigeria|Africa|Lagos
ZA|South Africa|Africa|Johannesburg
AQ|Fake Antarctica|Antarctica|Troll
HK|Hong Kong|Asia|Hong Kong
IN|India|Asia|Fake Mumbai,Mumbai,New Delhi
ID|Indonesia|Asia|Bali,Jakarta,Surabaya
JP|Japan|Asia|Tokyo
MY|Malaysia|Asia|Kuala Lumpur
PH|Philippines|Asia|Manila
RU|Russia|Asia|Fake St Petersburg
SG|Singapore|Asia|Singapore
KR|South Korea|Asia|Seoul
TW|Taiwan|Asia|Taipei
TH|Thailand|Asia|Bangkok
AE|United Arab Emirates|Asia|Dubai
VN|Vietnam|Asia|Hanoi
AL|Albania|Europe|Tirana
AT|Austria|Europe|Vienna
BE|Belgium|Europe|Brussels
BA|Bosnia|Europe|Novi Travnik,Sarajevo
BG|Bulgaria|Europe|Sofia
HR|Croatia|Europe|Zagreb
CY|Cyprus|Europe|Limassol,Nicosia
CZ|Czech Republic|Europe|Prague
DK|Denmark|Europe|Copenhagen
EE|Estonia|Europe|Tallinn
FI|Finland|Europe|Helsinki
FR|France|Europe|Bordeaux,Marseille,Paris
GE|Georgia|Europe|Tbilisi
DE|Germany|Europe|Berlin,Frankfurt
GR|Greece|Europe|Athens
HU|Hungary|Europe|Budapest
IS|Iceland|Europe|Reykjavik
IE|Ireland|Europe|Dublin
IT|Italy|Europe|Milan,Palermo
LV|Latvia|Europe|Riga
LT|Lithuania|Europe|Vilnius
LU|Luxembourg|Europe|Luxembourg
MD|Moldova|Europe|Chisinau
NL|Netherlands|Europe|Amsterdam
MK|North Macedonia|Europe|Skopje
NO|Norway|Europe|Oslo
PL|Poland|Europe|Gdansk,Warsaw
PT|Portugal|Europe|Lisbon
RO|Romania|Europe|Bucharest
RS|Serbia|Europe|Belgrade
SK|Slovakia|Europe|Bratislava
SI|Slovenia|Europe|Ljubljana
ES|Spain|Europe|Barcelona,Madrid
SE|Sweden|Europe|Stockholm
CH|Switzerland|Europe|Zurich
TR|Turkey|Europe|Istanbul
UA|Ukraine|Europe|Kyiv
GB|United Kingdom|Europe|Edinburgh,London,Manchester,Shamchester
CA|Canada East|North America|Halifax,Montreal,Toronto
CA|Canada West|North America|Calgary,Vancouver,Winnipeg
SV|El Salvador|North America|San Salvador
GT|Guatemala|North America|Guatemala City
MX|Mexico|North America|Queretaro
PA|Panama|North America|Panama City
US|US Central|North America|Atlanta,Dallas,Denver,Houston,Kansas City
US|US East|North America|Ashburn,Boston,Buffalo,Charlotte,Chicago,Cleveland,Detroit,Miami,New Jersey,New York,Philadelphia,Raleigh,South Bend,Tampa,Washington DC
US|US West|North America|Bend,Honolulu,Las Vegas,Los Angeles,Phoenix,Salt Lake City,San Francisco,San Jose,Santa Clara,Seattle
AU|Australia|Oceania|Adelaide,Brisbane,Melbourne,Perth,Sydney
NZ|New Zealand|Oceania|Auckland
AR|Argentina|South America|Buenos Aires
BR|Brazil|South America|Sao Paulo
CL|Chile|South America|Santiago
CO|Colombia|South America|Bogota
EC|Ecuador|South America|Quito
PY|Paraguay|South America|Asuncion
PE|Peru|South America|Lima
UY|Uruguay|South America|Montevideo
"""
}
