import csv
G="Jacksonville Jaguars @ New York Giants (Sun 11/22 4:25 PM)"
T="2026-11-22 01:18"
rows=[]
def add(book,mkt,data,url):
    for p,l,o,u in data: rows.append([book,G,mkt,p,l,o,u,T,url])
dk="https://sportsbook.draftkings.com/event/jax-jaguars-%40-ny-giants/34118110"
mg="https://www.pa.betmgm.com/en/sports/events/jacksonville-jaguars-new-york-giants-6:44057"
cz="https://sportsbook.caesars.com/sport/americanfootball/event/c3a79427-2887-e1f2-8c2f-348a4af876a7"
def ou(s):
    out=[]
    for line in s.strip().splitlines():
        p,l,o,u=[x.strip() for x in line.split('|')]
        out.append((p,l,o,u))
    return out
def n(s): return s.replace('−','-')
# DraftKings
add('DraftKings','passing_yards',ou("""Trevor Lawrence|230.5|-113|-111
J.J. McCarthy|210.5|-114|-111"""),dk+"?category=odds&subcategory=pass-yards-o%2Fu")
add('DraftKings','rushing_yards',ou("""Bhayshul Tuten|70.5|-110|-114
Cameron Skattebo|53.5|-113|-111
Chris Rodriguez Jr.|20.5|-114|-110
J.J. McCarthy|17.5|-109|-115
Devin Singletary|11.5|-106|-118
Trevor Lawrence|9.5|-115|-109"""),dk+"?category=odds&subcategory=rush-yards-o%2Fu")
add('DraftKings','receiving_yards',ou("""Malik Nabers|69.5|-114|-110
Parker Washington|66.5|-113|-111
Isaiah Likely|48.5|-111|-113
Jakobi Meyers|40.5|-110|-114
Brenton Strange|31.5|-114|-110
Malachi Fields|30.5|-115|-109
Darnell Mooney|16.5|-110|-114
Cameron Skattebo|12.5|-118|-106
Bhayshul Tuten|12.5|-116|-108
Nate Boerkircher|11.5|-118|-107
Josh Cameron|11.5|-113|-111
Brian Thomas Jr.|11.5|-111|-113
Travis Hunter|7.5|-117|-107
Theo Johnson|7.5|-108|-116"""),dk+"?category=odds&subcategory=rec-yards-o%2Fu")
rc="""Malik Nabers|5.5|-121|-105
Isaiah Likely|5.5|+115|-146
Parker Washington|4.5|+102|-130
Brenton Strange|3.5|+133|-171
Jakobi Meyers|3.5|+135|-173
Malachi Fields|2.5|+108|-138
Cameron Skattebo|2.5|+121|-155
Bhayshul Tuten|1.5|-173|+135
Darnell Mooney|1.5|+105|-134
Nate Boerkircher|1.5|+116|-148
Josh Cameron|1.5|+139|-179
Brian Thomas Jr.|1.5|+142|-182
Travis Hunter|1.5|+161|-207
Theo Johnson|0.5|-186|+145"""
add('DraftKings','receptions',ou(rc),dk+"?category=odds&subcategory=receptions-o%2Fu")
dktd="""Bhayshul Tuten|-115
Cameron Skattebo|+110
Parker Washington|+140
Malik Nabers|+180
Isaiah Likely|+235
Jakobi Meyers|+245
Chris Rodriguez Jr.|+250
Brenton Strange|+300
Malachi Fields|+450
Trevor Lawrence|+475
Nate Boerkircher|+475
Devin Singletary|+500
J.J. McCarthy|+500
Brian Thomas Jr.|+600
Travis Hunter|+600
Darnell Mooney|+650
Josh Cameron|+700
Theo Johnson|+850
Jameis Winston|+1000
LeQuint Allen|+1100"""
add('DraftKings','anytime_td',[(a.split('|')[0],'',a.split('|')[1],'') for a in dktd.splitlines()],dk+"?category=odds&subcategory=td-scorers")
# BetMGM
add('BetMGM','passing_yards',ou("""J.J. McCarthy|211.5|-110|-120
Trevor Lawrence|236.5|+100|-135"""),mg+"?market=Players:Passing")
add('BetMGM','rushing_yards',ou("""Chris Rodriguez Jr.|18.5|-120|-110
J.J. McCarthy|17.5|-120|-110
Cam Skattebo|54.5|-115|-115
Bhayshul Tuten|72.5|-111|-118"""),mg+"?market=Players:Rushing")
add('BetMGM','receiving_yards',ou("""Malachi Fields|27.5|-135|+100
Parker Washington|64.5|-125|-105
Cam Skattebo|14.5|-120|-110
Bhayshul Tuten|13.5|-115|-115
Brenton Strange|31.5|-115|-115
Brian Thomas Jr.|12.5|-115|-115
Darnell Mooney|15.5|-115|-115
Jakobi Meyers|40.5|-115|-115
Josh Cameron|10.5|-115|-115
Malik Nabers|66.5|-115|-115
Theo Johnson|6.5|-115|-115
Nate Boerkircher|10.5|-110|-120
Isaiah Likely|49.5|+100|-135"""),mg+"?market=Players:Receiving")
add('BetMGM','receptions',ou("""Theo Johnson|0.5|-200|+150
Bhayshul Tuten|1.5|-190|+140
Brenton Strange|2.5|-165|+125
Isaiah Likely|4.5|-165|+125
Malik Nabers|5.5|-120|-110
Darnell Mooney|1.5|-105|-125
Cam Skattebo|2.5|+100|-135
Parker Washington|4.5|+100|-135
Jakobi Meyers|3.5|+105|-140
Malachi Fields|2.5|+105|-140
Brian Thomas Jr.|1.5|+135|-185
Josh Cameron|1.5|+138|-190"""),mg+"?market=Players:Receiving")
mgtd="""Bhayshul Tuten|-118
Cam Skattebo|-110
Parker Washington|+135
Malik Nabers|+190
Isaiah Likely|+200
Chris Rodriguez Jr.|+250
Jakobi Meyers|+250
Brenton Strange|+280
Trevor Lawrence|+390
J.J. McCarthy|+425
Malachi Fields|+425
Brian Thomas Jr.|+525
Nate Boerkircher|+575
Josh Cameron|+600
Devin Singletary|+650
Darnell Mooney|+700
Travis Hunter|+700
Theo Johnson|+900"""
add('BetMGM','anytime_td',[(a.split('|')[0],'',a.split('|')[1],'') for a in mgtd.splitlines()],mg+"?market=Players:TDScorers")
# Caesars
add('Caesars','passing_yards',ou("""Trevor Lawrence|232.5|-107|-127
J.J. McCarthy|211.5|-108|-125"""),cz)
add('Caesars','rushing_yards',ou("""Bhayshul Tuten|70.5|-115|-113
Cam Skattebo|54.5|-115|-113
Chris Rodriguez Jr.|20.5|-125|-108
J.J. McCarthy|16.5|-117|-113
Devin Singletary|10.5|-115|-114
Trevor Lawrence|9.5|-115|-114"""),cz)
add('Caesars','receiving_yards',ou("""Malik Nabers|68.5|-120|-112
Parker Washington|66.5|-135|+102
Isaiah Likely|47.5|-107|-127
Jakobi Meyers|41.5|-117|-112
Brenton Strange|32.5|-117|-112
Malachi Fields|30.5|-114|-114
Darnell Mooney|15.5|-110|-118
Cam Skattebo|13.5|-114|-114
Bhayshul Tuten|13.5|-112|-117
Brian Thomas Jr.|12.5|-107|-125
Nate Boerkircher|11.5|-117|-113
Josh Cameron|11.5|-113|-115
Travis Hunter|8.5|-112|-118
Theo Johnson|7.5|-110|-120"""),cz)
add('Caesars','receptions',ou("""Malik Nabers|5.5|-127|-103
Isaiah Likely|5.5|+122|-170
Parker Washington|4.5|+103|-134
Jakobi Meyers|3.5|+120|-150
Brenton Strange|2.5|-164|+125
Malachi Fields|2.5|+113|-148
Cam Skattebo|2.5|+118|-145
Bhayshul Tuten|1.5|-173|+131
Darnell Mooney|1.5|-103|-127
Nate Boerkircher|1.5|+122|-159
Josh Cameron|1.5|+146|-193
Brian Thomas Jr.|1.5|+155|-200
Travis Hunter|1.5|+157|-209
Theo Johnson|0.5|-190|+140"""),cz)
cztd="""Bhayshul Tuten|-115
Cam Skattebo|+104
Parker Washington|+137
Jameis Winston|+1000
Malik Nabers|+184
Jakobi Meyers|+240
Chris Rodriguez Jr.|+250
Isaiah Likely|+220
Brenton Strange|+285
Phil Mafah|+1900
Trevor Lawrence|+450
Nate Boerkircher|+475
Malachi Fields|+450
J.J. McCarthy|+475
Devin Singletary|+475
Brian Thomas Jr.|+550
Travis Hunter|+600
Darnell Mooney|+625
Josh Cameron|+625
Theo Johnson|+750"""
add('Caesars','anytime_td',[(a.split('|')[0],'',a.split('|')[1],'') for a in cztd.splitlines()],cz)
w=csv.writer(open('sample_2026-11-22.csv','w',newline=''))
w.writerow("book,game,market,player,line,over_odds,under_odds,captured_at_et,page_url".split(','))
w.writerows(rows)
from collections import Counter
print(Counter((r[0],r[2]) for r in rows))
