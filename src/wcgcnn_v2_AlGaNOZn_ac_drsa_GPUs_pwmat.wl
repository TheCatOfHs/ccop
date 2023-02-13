Predict Network
Clear["Global`*"]
Graph Convolution
mygru[fea_]:=NetGraph[
	{"Cate"->CatenateLayer[1],
	"W"->LinearLayer[{fea},"Weights"->Table[0.,fea,2*fea]],
	"Sigmoid"->ElementwiseLayer["Sigmoid"],
	"Wsum"->ThreadingLayer[#Weight*#Value1+(1-#Weight)*#Value2&]},
	
	{{NetPort["OAtom"],NetPort["NAtom"]}->"Cate",
	"Cate"->"W"->"Sigmoid",
	NetPort["OAtom"]->NetPort["Wsum","Value1"],
	NetPort["NAtom"]->NetPort["Wsum","Value2"],
	"Sigmoid"->NetPort["Wsum","Weight"]}
];
weightsum[near_]:=NetChain[
	{TransposeLayer[2<->3],
	NetMapOperator[NetMapOperator[LinearLayer[{},"Weights"->Table[1/near,1,near]]]]}
];
conv[atomfea_,bondfea_,near_]:=NetGraph[
	{"BN1"->NetMapOperator[NetMapOperator[BatchNormalizationLayer["Momentum"->.1]]],
	"BN2"->NetMapOperator[BatchNormalizationLayer["Momentum"->.1]],
	"SoftPlus1"->ElementwiseLayer["SoftPlus"],
	"SoftPlus2"->ElementwiseLayer["SoftPlus"],
	"Sigmoid"->ElementwiseLayer["Sigmoid"],
	
	"Near"->ExtractLayer[],
	"NearAtom"->ReshapeLayer[{Automatic,near,atomfea}],
	"Cate"->CatenateLayer[3],
	"AtomTensor"->NetMapOperator[ReplicateLayer[near]],
	
	"Wsf"->NetMapOperator[NetMapOperator[{2*atomfea}]],
	"Core"->PartLayer[{All,All,1;;atomfea}],
	"Filter"->PartLayer[{All,All,atomfea+1;;-1}],
	"Times"->ThreadingLayer[Times],
	"Sum"->weightsum[near],
	"NewAtom"->NetMapThreadOperator[mygru[atomfea],"OAtom"->{"Varying",atomfea},"NAtom"->{"Varying",atomfea}]},
	
	{NetPort["Atom"]->"AtomTensor",
	NetPort["Atom"]->NetPort["Near","Input"],
	NetPort["NearIndex"]->NetPort["Near","Position"],
	"Near"->"NearAtom",
	{"AtomTensor","NearAtom",NetPort["Bond"]}->"Cate",
	"Cate"->"Wsf"->"BN1",
	"BN1"->"Core",
	"BN1"->"Filter",
	"Core"->"SoftPlus1",
	"Filter"->"Sigmoid",
	{"SoftPlus1","Sigmoid"}->"Times",
	"Times"->"Sum"->"BN2",
	NetPort["Atom"]->NetPort["NewAtom","OAtom"],
	"BN2"->NetPort["NewAtom","NAtom"],
	"NewAtom"->"SoftPlus2"}
];
Conv Block
convblock[atomfea_,bondfea_,near_]:=NetGraph[
	{"Conv1"->conv[atomfea,bondfea,near],
	"Conv2"->conv[atomfea,bondfea,near],
	"Conv3"->conv[atomfea,bondfea,near],
	"Pool"->NetChain[{AggregationLayer[Mean,1]}]},
	
	{NetPort["Atom"]->NetPort["Conv1","Atom"],
	NetPort["Bond"]->NetPort["Conv1","Bond"],
	NetPort["NearIndex"]->NetPort["Conv1","NearIndex"],
	
	"Conv1"->NetPort["Conv2","Atom"],
	NetPort["Bond"]->NetPort["Conv2","Bond"],
	NetPort["NearIndex"]->NetPort["Conv2","NearIndex"],
	
	"Conv2"->NetPort["Conv3","Atom"],
	NetPort["Bond"]->NetPort["Conv3","Bond"],
	NetPort["NearIndex"]->NetPort["Conv3","NearIndex"],
	"Conv3"->"Pool"}
];
Readout
readout[cryfea_]:=NetGraph[
	{"Linear1"->LinearLayer[{cryfea}],
	"Linear2"->LinearLayer[{}],
	"SoftPlus"->ElementwiseLayer["SoftPlus"]},
	
	{NetPort["CrystallFea"]->"Linear1",
	"Linear1"->"SoftPlus",
	"SoftPlus"->"Linear2"}
];
WCGCNN
wcgcnn[n_,atomfea_,embedfea_,bondfea_,cryfea_,near_,atom_]:=NetGraph[
	{"Atom"->NetArrayLayer["Array"->atom,LearningRateMultipliers->0.],
	"Embed"->NetMapOperator[{embedfea},"Input"->{"Varying",atomfea}],
	"GConv"->convblock[embedfea,bondfea,near],
	"Readout"->readout[cryfea],
	"MSE"->MeanSquaredLossLayer[]},
	
	{"Atom"->"Embed",
	"Embed"->NetPort["GConv","Atom"],
	NetPort["Bond"]->NetPort["GConv","Bond"],
	NetPort["NearIndex"]->NetPort["GConv","NearIndex"],
	"GConv"->"Readout",
	"Readout"->NetPort["MSE","Input"],
	NetPort["Energy"]->NetPort["MSE","Target"]},
	
	"Bond"->{"Varying",near,bondfea},
	"NearIndex"->{n*near,1}
];
Choose Best Nets
netfilter[n_,w1_,w2_,dir_]:=Block[
	{l1,l2,l3,l4,len,par,nets,save,loss,loss1,loss2,roundloss,roundnets,bestindex,bestindexes},
	len=FileNames[All,dir]//Length;
	nets=FileNames[All,dir,{2}];
	par=Length@nets/len;
	roundnets=Partition[nets,par];
	l1=StringTake[#,-13;;-7]&/@nets;
	l2=StringTake[#,-21;;-15]&/@nets;
	{loss1,loss2}=StringCases[#,a__~~"e"~~b__:>ToExpression[a]*10^ToExpression[b]]&/@{l1,l2};
	loss=Flatten[w1*loss1+w2*loss2];
	roundloss=Partition[loss,par];
	bestindex=Ordering[loss,1];
	bestindexes=Ordering[#,If[n==1,1,n/len]]&/@roundloss;
	l3=nets[[bestindex]];
	l4=MapThread[#1[[#2]]&,{roundnets,bestindexes}]//Flatten;
	save=Join[l3,Complement[l4,l3]];
	If[n==1,
		Import[#]&@save[[1]],
		Import[#]&/@save
	]
];
Environment
Energy Predict
predictEn[\[Mu]_,\[Sigma]_,bond_,near_,energynet_,tgpu_]:=Block[
	{},
	\[Mu]+\[Sigma]*energynet[<|"Bond"->bond,"NearIndex"->near|>,BatchSize->1024,TargetDevice->{"GPU",tgpu}]
];
predictEnBatch[\[Mu]_,\[Sigma]_,bond_,near_,energynets_,tgpu_]:=Block[
	{},
	(\[Mu]+\[Sigma]*#[<|"Bond"->bond,"NearIndex"->near|>,BatchSize->1024,TargetDevice->{"GPU",tgpu}])&/@energynets
];
Feature Predict
predictFea[bond_,near_,featurenet_,tgpu_]:=Block[
	{},
	featurenet[<|"Bond"->bond,"NearIndex"->near|>,BatchSize->1024,TargetDevice->{"GPU",tgpu}]
];
Action Pair
actionSpace=Block[
	{a,b,c,d,e,l1,l2,l3,l4},
	{a,b,c}=Range[36]//Partition[#,12]&;
	{d,e}=Range[37,72]//Partition[#,18]&;
	l1=Table[{i,j},{i,a},{j,b}]//Flatten[#,1]&;
	l2=Table[{i,j},{i,a},{j,c}]//Flatten[#,1]&;
	l3=Table[{i,j},{i,b},{j,c}]//Flatten[#,1]&;
	l4=Table[{i,j},{i,d},{j,e}]//Flatten[#,1]&;
	Join[l1,l2,l3,l4]
];
aSpaceLen=Length@actionSpace;
Search Network
Actor
actor[]:=NetInitialize[#,Method->{"Xavier","Distribution"->"Uniform"}]&@
	NetChain[{256,Tanh,aSpaceLen,SoftmaxLayer[]},
		"Input"->72
];
Critic
critic[]:=NetInitialize@
	NetChain[{512,ElementwiseLayer["SELU"],
		256,ElementwiseLayer["SELU"],
		256,ElementwiseLayer["SELU"],{}},
		"Input"->72
];

criticNet[]:=NetGraph[
	{"Critic1"->critic[],
	"Critic2"->critic[],
	"Plus"->ThreadingLayer[#1+.99#2-#3&],
	"Zero"->NetArrayLayer["Array"->0,"Output"->{},LearningRateMultipliers->0.],
	"MSE"->MeanSquaredLossLayer[]},
	
	{NetPort["State1"]->"Critic1",
	NetPort["State2"]->"Critic2",
	{NetPort["Reward"],"Critic2","Critic1"}->"Plus",
	"Plus"->NetPort["MSE","Input"],
	"Zero"->NetPort["MSE","Target"],
	"MSE"->NetPort["CriticLoss"],
	"Plus"->NetPort["Advantage"]}
];
AC Network
netPPO2[]:=NetGraph[
	{"Actor"->actor[],
	"CriticNet"->criticNet[],
	"Times"->ThreadingLayer[Times],
	"P1"->AggregationLayer[Total,1],
	"Clip"->ThreadingLayer[-Min[#1/(#2+10^-8)*#3,Clip[#1/(#2+10^-8),{.8,1.2}]*#3]&]},
	
	{NetPort["State1"]->"Actor",
	{"Actor",NetPort["Action"]}->"Times"->"P1",
	NetPort["State1"]->NetPort["CriticNet","State1"],
	NetPort["State2"]->NetPort["CriticNet","State2"],
	{"P1",NetPort["P2"],NetPort["CriticNet","Advantage"]}->"Clip",
	"Clip"->NetPort["PPO2Loss"]}
];
Soft Update
Critic Soft  Updating
criticUpdate[\[Tau]_,key1_,key2_,net1_,net2_]:=Block[
	{unet,net1w1,net1b1,net1w2,net1b2,net1w3,net1b3,net1w4,net1b4,
	net2w1,net2b1,net2w2,net2b2,net2w3,net2b3,net2w4,net2b4},
	unet=net1;
	net1w1=net1[["CriticNet",key1,1,"Weights"]]//Normal;
	net1b1=net1[["CriticNet",key1,1,"Biases"]]//Normal;
	net1w2=net1[["CriticNet",key1,3,"Weights"]]//Normal;
	net1b2=net1[["CriticNet",key1,3,"Biases"]]//Normal;
	net1w3=net1[["CriticNet",key1,5,"Weights"]]//Normal;
	net1b3=net1[["CriticNet",key1,5,"Biases"]]//Normal;
	net1w4=net1[["CriticNet",key1,7,"Weights"]]//Normal;
	net1b4=net1[["CriticNet",key1,7,"Biases"]]//Normal;
	net2w1=net2[["CriticNet",key2,1,"Weights"]]//Normal;
	net2b1=net2[["CriticNet",key2,1,"Biases"]]//Normal;
	net2w2=net2[["CriticNet",key2,3,"Weights"]]//Normal;
	net2b2=net2[["CriticNet",key2,3,"Biases"]]//Normal;
	net2w3=net1[["CriticNet",key2,5,"Weights"]]//Normal;
	net2b3=net1[["CriticNet",key2,5,"Biases"]]//Normal;
	net2w4=net1[["CriticNet",key2,7,"Weights"]]//Normal;
	net2b4=net1[["CriticNet",key2,7,"Biases"]]//Normal;
	unet=NetReplacePart[unet,
		{{"CriticNet",key2,1,"Weights"}->\[Tau]*net1w1+(1.-\[Tau])net2w1,
		{"CriticNet",key2,1,"Biases"}->\[Tau]*net1b1+(1.-\[Tau])net2b1,
		{"CriticNet",key2,3,"Weights"}->\[Tau]*net1w2+(1.-\[Tau])net2w2,
		{"CriticNet",key2,3,"Biases"}->\[Tau]*net1b2+(1.-\[Tau])net2b2,
		{"CriticNet",key2,5,"Weights"}->\[Tau]*net1w3+(1.-\[Tau])net2w3,
		{"CriticNet",key2,5,"Biases"}->\[Tau]*net1b3+(1.-\[Tau])net2b3,
		{"CriticNet",key2,7,"Weights"}->\[Tau]*net1w4+(1.-\[Tau])net2w4,
		{"CriticNet",key2,7,"Biases"}->\[Tau]*net1b4+(1.-\[Tau])net2b4}
	];
	unet
];
DRSA Sampling
Position List to Atom List
pos2atom=Compile[{{poslist,_Real,1}},
	Block[{al,pos,atom},
		al=Table[1.,72];
		Do[
			pos=Round@Compile`GetElement[poslist,i];
			al=ReplacePart[al,
				If[1<=i<13,
					1.,If[13<=i<25,
						2.,If[25<=i<37,
							3.,If[37<=i<55,
								4.,5.
							]
						]
					]
				],
				pos
			],
			{i,Length@poslist}
		];
		al
	],
	CompilationTarget->"C",RuntimeOptions->"Speed",
	RuntimeAttributes->{Listable}
];
\[CurlyEpsilon]-Greedy
netValue[state_,net_]:=Block[
	{},
	net[state,BatchSize->1,TargetDevice->"GPU"]
];
exchange=Compile[{{\[Epsilon],_Real},{netvalue,_Real,1}},
	Block[{},
		If[RandomReal[]>\[Epsilon],
			RandomChoice[netvalue->Range[aSpaceLen]],
			RandomInteger[{1,aSpaceLen}]
		]
	],
	CompilationOptions->{"InlineCompiledFunctions"->True,"InlineExternalDefinitions"->True}
];
onehot=Compile[{{n,_Integer}},
	Block[{l},
		l=Table[0.,aSpaceLen];
		ReplacePart[l,1.,n]
	],
	CompilationTarget->"C",RuntimeOptions->"Speed",
	RuntimeAttributes->{Listable}
];
Change Position List
cposition=Compile[{{pospair,_Integer,1},{poslist,_Integer,1}},
	Block[{a,b,l,pos1,pos2},
		{a,b}=pospair;
		pos1=Compile`GetElement[poslist,a];
		pos2=Compile`GetElement[poslist,b];
		l=ReplacePart[poslist,pos1,b];
		ReplacePart[l,pos2,a]
	],
	CompilationOptions->{"InlineCompiledFunctions"->True,"InlineExternalDefinitions"->True}
];
Change Near Index and Bond Feature
nearChange=Compile[{{pospair,_Real,1},{near,_Real,2}},
	Block[{p,p1,p2,d1,d2,l1,l2},
		{d1,d2}=Dimensions@near;
		{p1,p2}=Round@pospair;
		l1=near;
		Do[
			Do[
				p=Compile`GetElement[near,i,j];
				If[p==p1,
					l1[[i,j]]=p2,
					If[p==p2,
						l1[[i,j]]=p1
					]
				],
				{j,d2}
			],
			{i,d1}
		];
		l2=ReplacePart[l1,Compile`GetElement[l1,p2],p1];
		ReplacePart[l2,Compile`GetElement[l1,p1],p2]
	],
	CompilationTarget->"C",RuntimeOptions->"Speed"
];
bondChange=Compile[{{pospair,_Real,1},{bond,_Real,3}},
	Block[{l,p1,p2},
		{p1,p2}=Round@pospair;
		l=ReplacePart[
			bond,Compile`GetElement[bond,p2],
			p1
		];
		ReplacePart[
			l,Compile`GetElement[bond,p1],
			p2
		]
	],
	CompilationTarget->"C",RuntimeOptions->"Speed"
];
oneStep=Compile[{{\[Epsilon],_Real},{poslist,_Integer,1},{netvalue,_Real,1},{aSpace,_Integer,2}},
	Block[{act,pospair,nposlist},
		act=exchange[\[Epsilon],netvalue];
		pospair=Compile`GetElement[aSpace,act];
		nposlist=cposition[Round@pospair,Round@poslist];
		Join[nposlist,{act}]
	],
	CompilationTarget->"C",RuntimeOptions->"Speed",
	CompilationOptions->{"InlineCompiledFunctions"->True,"InlineExternalDefinitions"->True}
];
metropolis=Compile[{{T,_Real},{e1,_Real},{e2,_Real}},
	Block[{\[Delta]E},
		\[Delta]E=e2-e1;
		If[RandomReal[]<Exp[-\[Delta]E/T],
			1.,0.
		]
	],
	CompilationTarget->"C",RuntimeOptions->"Speed"
];
Data Generator
generate1[\[Epsilon]_,steps_,\[Mu]_,\[Sigma]_,inibondfea_,ininear_,iniposlist_,energynets_,agent_,tgpu_]:=Block[
	{b,e,l,p,n,T,e1,e2,act,poslist,aSpace,netvalue,
	pospair,bondfea,nearindex,nposlist,nbondfea,nnearindex,energynet,
	eBag=Internal`Bag[],pBag=Internal`Bag[],
	bBag=Internal`Bag[],nBag=Internal`Bag[]},
	poslist=iniposlist;
	aSpace=actionSpace;
	bondfea=inibondfea;
	nearindex=ininear;
	T=1.;
	energynet=energynets[[tgpu]];
	e1=predictEn[\[Mu],\[Sigma],bondfea,Partition[Flatten[nearindex],1],energynet,tgpu];
	Do[
		netvalue=netValue[pos2atom@poslist,agent];
		l=oneStep[\[Epsilon],poslist,netvalue,aSpace];
		act=Part[l,-1];
		nposlist=Drop[l,-1];
		pospair=aSpace[[Round@act]];
		nbondfea=bondChange[pospair,bondfea];
		nnearindex=nearChange[pospair,nearindex];
		e2=predictEn[\[Mu],\[Sigma],nbondfea,Partition[Flatten[nnearindex],1],energynet,tgpu];
		
		If[metropolis[T,e1,e2]==1.,
			poslist=nposlist;
			bondfea=nbondfea;
			nearindex=nnearindex;
			e1=e2;
			Internal`StuffBag[eBag,e2];
			Internal`StuffBag[pBag,nposlist];
			Internal`StuffBag[bBag,nbondfea];
			Internal`StuffBag[nBag,nnearindex]
		];
		T=.97*T,
		{i,steps}
	];
	e=Internal`BagPart[eBag,All];
	p=Internal`BagPart[pBag,All];
	b=Internal`BagPart[bBag,All];
	n=Internal`BagPart[nBag,All];
	{e,p,b,n}
];
generate2[\[Epsilon]_,steps_,\[Mu]_,\[Sigma]_,inibondfea_,ininear_,iniposlist_,energynet_,agent_,tgpu_]:=Block[
	{a,e,l,p1,p2,v,T,e1,e2,nv,act,poslist,aSpace,netvalue,
	pospair,bondfea,nearindex,nposlist,nbondfea,nnearindex,
	aBag=Internal`Bag[],eBag=Internal`Bag[],
	pBag1=Internal`Bag[],pBag2=Internal`Bag[],
	vBag=Internal`Bag[]},
	poslist=iniposlist;
	aSpace=actionSpace;
	bondfea=inibondfea;
	nearindex=ininear;
	T=1.;
	e1=predictEn[\[Mu],\[Sigma],bondfea,Partition[Flatten[nearindex],1],energynet,tgpu];
	Do[
		netvalue=netValue[pos2atom@poslist,agent];
		l=oneStep[\[Epsilon],poslist,netvalue,aSpace];
		act=Part[l,-1];
		nposlist=Drop[l,-1];
		pospair=aSpace[[Round@act]];
		nbondfea=bondChange[pospair,bondfea];
		nnearindex=nearChange[pospair,nearindex];
		e2=predictEn[\[Mu],\[Sigma],nbondfea,Partition[Flatten[nnearindex],1],energynet,tgpu];
		
		Internal`StuffBag[pBag1,poslist];
		If[metropolis[T,e1,e2]==1.,
			poslist=nposlist;
			bondfea=nbondfea;
			nearindex=nnearindex;
			e1=e2
		];
		nv=netvalue[[Round@act]];
		Internal`StuffBag[aBag,act];
		Internal`StuffBag[eBag,e2];
		Internal`StuffBag[pBag2,nposlist];
		Internal`StuffBag[vBag,nv];
		T=.97*T,
		{i,steps}
	];
	a=Internal`BagPart[aBag,All];
	e=Internal`BagPart[eBag,All];
	p1=Internal`BagPart[pBag1,All];
	p2=Internal`BagPart[pBag2,All];
	v=Internal`BagPart[vBag,All];
	{a,e,p1,p2,v}
];
Sampling
sampling1[\[Epsilon]_,paths_,steps_,\[Mu]_,\[Sigma]_,inibondfea_,ininear_,iniposlist_,energynets_,agent_,tgpu_]:=Block[
	{b,e,p,n,ens,poslist,bondfea,nearindex},
	ens={};
	poslist={};
	bondfea={};
	nearindex={};
	Do[
		{e,p,b,n}=generate1[\[Epsilon],steps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynets,agent,tgpu];
		ens=Join[ens,e];
		poslist=Join[poslist,p];
		bondfea=Join[bondfea,b];
		nearindex=Join[nearindex,n]
		,
		{i,paths}
	];
	nearindex=Partition[#,1]&/@Flatten/@nearindex;
	{ens,poslist,bondfea,nearindex}
];
sampling2[min_,\[Epsilon]_,paths_,steps_,\[Mu]_,\[Sigma]_,inibondfea_,ininear_,iniposlist_,energynet_,agent_,tgpu_]:=Block[
	{a,e,p1,p2,v,ens,rew,state1,state2,value,action},
	action={};
	ens={};
	value={};
	state1={};
	state2={};
	Do[
		{a,e,p1,p2,v}=generate2[\[Epsilon],steps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynet,agent,tgpu];
		action=Join[action,a];
		ens=Join[ens,e];
		value=Join[value,v];
		state1=Join[state1,pos2atom@p1];
		state2=Join[state2,pos2atom@p2]
		,
		{i,paths}
	];
	rew=(min-ens)/steps;
	<|"State1"->state1,"State2"->state2,"Action"->onehot[action],"P2"->value,"Reward"->rew|>
];
Parallel Sampling
psampling1[\[Epsilon]_,paths_,steps_,\[Mu]_,\[Sigma]_,inibondfea_,ininear_,iniposlist_,energynets_,agent_,gpus_]:=Block[
	{},
	ParallelEvaluate[
		sampling1[\[Epsilon],paths,steps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynets,agent,$KernelID],
		Range@gpus
	]
];
Buffer Sampling
sample[n_,buffer_]:=Block[{l},
	l=RandomSample[Range[Length@buffer[[1]]],n];
	Map[Part[#,l]&,
		buffer
	]
];
Position List to Coordinate
pos2coor=Compile[{{poslist,_Real,1},{sort,_Integer,1},{inicoor,_Real,2}},
	Block[{a,b,c,d,e,s,l1,l2,l3,l4},
		{a,b}=Partition[Take[inicoor,24],12];
		c=Take[inicoor,-12];
		{d,e}=Partition[Take[inicoor,{25,60}],18];
		l1=Join[a,c,b,d,e];
		l2=l1[[Round@poslist]];
		l3=Take[l2,36];
		l4=Take[l2,-36];
		Join[l3[[1;;12]],l3[[25;;36]],l4,l3[[13;;24]]]
	],
	CompilationTarget->"C",RuntimeOptions->"Speed",
	RuntimeAttributes->{Listable}
];
Estimate
Score
scoreCore[\[Epsilon]_,steps_,\[Mu]_,\[Sigma]_,inibondfea_,ininear_,iniposlist_,energynet_,agent_,tgpu_]:=Block[
	{b,e,l,p,n,T,e1,e2,act,poslist,aSpace,netvalue,
	pospair,bondfea,nearindex,nposlist,nbondfea,nnearindex,
	eBag=Internal`Bag[],pBag=Internal`Bag[],
	bBag=Internal`Bag[],nBag=Internal`Bag[]},
	poslist=iniposlist;
	aSpace=actionSpace;
	bondfea=inibondfea;
	nearindex=ininear;
	T=1.;
	e1=predictEn[\[Mu],\[Sigma],bondfea,Partition[Flatten[nearindex],1],energynet,tgpu];
	Do[
		netvalue=netValue[pos2atom@poslist,agent];
		l=oneStep[\[Epsilon],poslist,netvalue,aSpace];
		act=Part[l,-1];
		nposlist=Drop[l,-1];
		pospair=aSpace[[Round@act]];
		nbondfea=bondChange[pospair,bondfea];
		nnearindex=nearChange[pospair,nearindex];
		e2=predictEn[\[Mu],\[Sigma],nbondfea,Partition[Flatten[nnearindex],1],energynet,tgpu];
		
		If[metropolis[T,e1,e2]==1.,
			poslist=nposlist;
			bondfea=nbondfea;
			nearindex=nnearindex;
			e1=e2
		];
		Internal`StuffBag[eBag,e2];
		Internal`StuffBag[pBag,nposlist];
		Internal`StuffBag[bBag,nbondfea];
		Internal`StuffBag[nBag,nnearindex];
		T=.97*T,
		{i,steps}
	];
	e=Internal`BagPart[eBag,All];
	p=Internal`BagPart[pBag,All];
	b=Internal`BagPart[bBag,All];
	n=Internal`BagPart[nBag,All];
	{e,p,b,n}
];
score[\[Epsilon]_,paths_,steps_,\[Mu]_,\[Sigma]_,inibondfea_,ininear_,iniposlist_,energynet_,agent_,tgpu_]:=Block[
	{b,e,p,n,ml,ens,len,poslist,bondfea,nearindex},
	ens={};
	poslist={};
	bondfea={};
	nearindex={};
	Do[
		{e,p,b,n}=scoreCore[\[Epsilon],steps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynet,agent,tgpu];
		ens=Join[ens,e];
		poslist=Join[poslist,p];
		bondfea=Join[bondfea,b];
		nearindex=Join[nearindex,n]
		,
		{i,paths}
	];
	nearindex=Partition[#,1]&/@Flatten/@nearindex;
	len=Length@ens;
	ml=Ordering[ens,5];
	#[[ml]]&/@{ens,poslist,bondfea,nearindex}
];
Network Training
Predict Network Training
predictTrain[i_,w1_,w2_,dir2_,saveaddr_,wcgnet_,trainbond_,trainindex_,trainens_,valbond_,valindex_,valens_,nets_]:=Block[
	{netdir,bestnet,netsavedir},
	netsavedir=dir2<>saveaddr[i];
	CreateDirectory[netsavedir];
	Do[
		Print[StringTemplate["Rounds: ``-``"][i,j]];
		netdir=netsavedir<>StringPadLeft[ToString[j],2,"0"];
		NetTrain[wcgnet,<|"Bond"->trainbond,"NearIndex"->trainindex,"Energy"->trainens|>,All,
			ValidationSet-><|"Bond"->valbond,"NearIndex"->valindex,"Energy"->valens|>,
			BatchSize->64,MaxTrainingRounds->60,
			TrainingProgressReporting->None,
			RandomSeeding->Automatic,
			TargetDevice->{"GPU",All},
			TrainingProgressCheckpointing->{"Directory",netdir,"Interval"->Quantity[1,"Rounds"]},
			LearningRateMultipliers->{{"GConv","Conv1","Sum"}->None,{"GConv","Conv2","Sum"}->None,{"GConv","Conv3","Sum"}->None,
				{"GConv","Conv1","NewAtom"}->None,{"GConv","Conv2","NewAtom"}->None,{"GConv","Conv3","NewAtom"}->None}
		];
		
		bestnet=netfilter[1,w1,w2,netsavedir];
		NetTrain[bestnet,<|"Bond"->trainbond,"NearIndex"->trainindex,"Energy"->trainens|>,All,
			ValidationSet-><|"Bond"->valbond,"NearIndex"->valindex,"Energy"->valens|>,
			BatchSize->64,MaxTrainingRounds->60,
			TrainingProgressReporting->None,
			RandomSeeding->Automatic,
			TargetDevice->{"GPU",All},
			TrainingProgressCheckpointing->{"Directory",netdir,"Interval"->Quantity[1,"Rounds"]}
		],
		{j,5}
	];
	netfilter[nets,w1,w2,netsavedir]
];
Agent Network Training
agentTrain[n_,dir_,min_,rounds_,paths_,steps_,\[Mu]_,\[Sigma]_,inibondfea_,ininear_,iniposlist_,energynet_,ppo2net_,tgpu_]:=Block[
	{\[Epsilon],ml,len,net,data,ndata,agent,energy,sublen,netPPO2,sampleens,samplelist,samplebond,sampleindex,
	bufferlist=Internal`Bag[],bufferbond=Internal`Bag[],bufferindex=Internal`Bag[],bufferens=Internal`Bag[]},
	\[Epsilon]=.9;
	netPPO2=NetReplacePart[ppo2net,"Actor"->actor[]];
	agent=netPPO2[["Actor"]];
	data=sampling2[min,\[Epsilon],100*paths,steps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynet,agent,tgpu];
	Do[
		len=Length@data[[1]];
		sublen=Round[.5*len];
		Do[
			net=NetTrain[netPPO2,sample[Round[.02*len],data],
				LossFunction->"CriticLoss",
				TrainingProgressReporting->None,
				BatchSize->1024,MaxTrainingRounds->1,
				RandomSeeding->Automatic,
				LearningRateMultipliers->{{"CriticNet","Critic1"}->1,{"CriticNet","Critic2"}->0,"Actor"->0},
				TargetDevice->{"GPU",All}
			];
			netPPO2=net;
			If[Mod[j,1]==0,
				netPPO2=criticUpdate[1.,"Critic1","Critic2",net,net]
			],
			{j,1}
		];
		Do[
			net=NetTrain[netPPO2,sample[Round[.02*sublen],Take[#,-sublen]&/@data],
				LossFunction->"PPO2Loss",
				TrainingProgressReporting->None,
				BatchSize->1024,MaxTrainingRounds->1,
				RandomSeeding->Automatic,
				LearningRateMultipliers->{{"CriticNet","Critic1"}->0,{"CriticNet","Critic2"}->0,"Actor"->1},
				TargetDevice->{"GPU",All}
			];
			netPPO2=net;
			agent=netPPO2[["Actor"]];
			ndata=sampling2[min,\[Epsilon],paths,steps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynet,agent,tgpu];
			data=Join[data,ndata,2];
			If[len>2000*steps,
				data=Drop[#,steps]&/@data
			];
			If[Mod[j,1]==0,
				{sampleens,samplelist,samplebond,sampleindex}=score[0.,paths,steps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynet,agent,tgpu];
				Print["Round: "<>StringPadLeft[ToString[i],4,"0"]<>" \[Epsilon]: "<>ToString[NumberForm[\[Epsilon],{4,2}]]<>" e: "<>ToString[sampleens]];
				Internal`StuffBag[bufferlist,samplelist];
				Internal`StuffBag[bufferbond,samplebond];
				Internal`StuffBag[bufferindex,sampleindex];
				Internal`StuffBag[bufferens,sampleens]
			],
			{j,1}
		];
		\[Epsilon]=.999*\[Epsilon],
		{i,rounds}
	];
	
	sampleens=Internal`BagPart[bufferens,All];
	Export[dir<>"/save/energys/"<>StringPadLeft[ToString[n],2,"0"]<>".txt",sampleens,"Table"];
	
	samplelist=Internal`BagPart[bufferlist,All]//Flatten[#,1]&;
	samplebond=Internal`BagPart[bufferbond,All]//Flatten[#,1]&;
	sampleindex=Internal`BagPart[bufferindex,All]//Flatten[#,1]&;
	sampleens=sampleens//Flatten[#,1]&;
	ml=Ordering[sampleens,10];
	{net,samplelist[[ml]],samplebond[[ml]],sampleindex[[ml]],sampleens[[ml]]}
];
Launch Kernels
Local Kernels
LaunchKernels[2];
Remote Kernels
Needs["SubKernels`RemoteKernels`"];
Parallel`Settings`$MathLinkTimeout=10000;
user="lcn";
password="199612qweasd";
ssh="plink -batch -D 22";
math="MathKernel -wstp -linkmode Connect `4` -linkname `2` -subkernel -noinit >& \/dev/null &";
number={1,1,1,1,1,1};
jobs={10,10,10,10,10,10};
jobup=FoldList[#1+#2&,jobs];
jobdown=FoldList[#1+#2&,Join[{1},Drop[jobs,-1]]];
machine={"node131","node132","node133","node134","node135","node136"};
cluster[machine_,number_]:=Block[{remote},
	remote=SubKernels`RemoteKernels`RemoteMachine[
		machine,
		ssh<>" "<>user<>"@"<>machine<>" -pw "<>password<>" \""<>math<>" \"",number
	]; 
	LaunchKernels[remote]
];
subjobs[i_,dir2_,machine_,number_,gpus_]:=Block[
	{n,kernel},
	n=Total@number;
	MapThread[cluster[#1,#2]&,{machine,number}];
	kernel=Kernels[];
	ParallelEvaluate[
		Map[
			RunProcess[{"sh",dir2<>"/buffer/sub/sub_vasp"<>ToString[#]}]&,
			Range@@(Thread[List[jobdown,jobup]][[$KernelID-gpus-n(i-1)]])
		],
		kernel[[-n;;-1]]
	];
	CloseKernels@kernel[[-n;;-1]]
];
Data Import
Data
alloy="/AlGaNOZn";
dir1="/public/BioPhys/lcn/ml/data_mask"<>alloy;
dir2=Directory[];
atom=Import[dir1<>alloy<>"_AtomFea.mtx.gz"];
dataens=Import[dir1<>alloy<>"_train_Energy.dat","Real64"];
dataindex=Partition[#,1]&/@Import[dir1<>alloy<>"_train_NearIndex.mtx.gz"];
databond=ArrayReshape[#,{72,12,40}]&/@Import[dir1<>alloy<>"_train_BondFea.mtx.gz"];
Train Data
trainens=dataens[[1;;30]];
trainbond=databond[[1;;30]];
trainindex=dataindex[[1;;30]];
Buffer Data
buffer=Range[30];
bufferlist=Table[Range[72],30];
bufferbond=trainbond;
bufferindex=trainindex;
bufferens=trainens;
Validation Data
valbond=databond[[151;;300]];
valindex=dataindex[[151;;300]];
Sample Initial Data
cifindex=1;
inifile=FileNames[All,"/public/BioPhys/lcn/ml/data"<>alloy<>"_small/initial"];
cif=inifile[[cifindex]];
initialens=Import[dir1<>alloy<>"_initial_Energy.dat","Real64"];
initialindex=Partition[#,1]&/@Import[dir1<>alloy<>"_initial_NearIndex.mtx.gz"];
initialbond=ArrayReshape[#,{72,12,40}]&/@Import[dir1<>alloy<>"_initial_BondFea.mtx.gz"];
iniens=initialens[[cifindex]];
inibondfea=initialbond[[cifindex]];
ininear=ArrayReshape[#,{72,12}]&@Flatten@initialindex[[cifindex]];
inicoor=Import[cif,"Table"][[27;;-1]][[All,4;;6]];
iniposlist=bufferlist[[cifindex]];
POSCAR File Head
poscarhead=Import[dir2<>"/buffer/POSCAR_head","Text"];
Network Initialize
\[Mu]=trainens//Mean;
\[Sigma]=trainens//StandardDeviation;
min=Min@trainens;
trainens=(trainens-\[Mu])/\[Sigma];
valens=(dataens[[151;;300]]-\[Mu])/\[Sigma];
wcgnet=wcgcnn[72,92,64,40,128,12,atom];
Agent
trainrounds=5;
addsamples=2*15;
samplesteps=3*25;
sort={1,5,2,3,4};
\[Epsilon]=.0;
gpus=2;
tgpu=2;
steps=3*25;
paths=1;
nets=5;
rounds=1000;
ppo2net=netPPO2[];
AC Searching
{w1,w2}={1.,.001};
recordmu=Internal`Bag[];
recordsigma=Internal`Bag[];
recordmin=Internal`Bag[];
saveaddr=StringTemplate["/check/GPUs/ac/``/"];
Print["Round Energy: ",iniens];
Print[StringTemplate["Length of Buffer: ``"][Length@buffer]];
Internal`StuffBag[recordmin,iniens];
Do[
	Internal`StuffBag[recordmu,\[Mu]];
	Internal`StuffBag[recordsigma,\[Sigma]];
	bestnets=predictTrain[i,w1,w2,dir2,saveaddr,wcgnet,trainbond,trainindex,trainens,valbond,valindex,valens,nets];
	Export[dir2<>"/save/conformers"<>alloy<>"_AC_Round_"<>ToString[i]<>".txt",
		pos2coor[iniposlist,sort,inicoor],"Table",Alignment->Left
	];
	
	energynets=NetDelete[#,"MSE"]&/@bestnets;
	featurenets=NetDelete[#,"Readout"]&/@energynets;
	energynet=energynets[[1]];
	featurenet=featurenets[[1]];
	
	ppo2Results=agentTrain[i,dir2,min,rounds,paths,steps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynet,ppo2net,tgpu];
	{ppo2net,samplelist,samplebond,sampleindex,sampleens}=ppo2Results;
	agent=ppo2net[["Actor"]];
	bufferlist=Join[bufferlist,samplelist];
	bufferbond=Join[bufferbond,samplebond];
	bufferindex=Join[bufferindex,sampleindex];
	bufferens=Join[bufferens,sampleens];
	
	sampledata=psampling1[\[Epsilon],20*paths,samplesteps,\[Mu],\[Sigma],inibondfea,ininear,iniposlist,energynets,agent,gpus];
	sampleens=Flatten[#,1]&@sampledata[[All,1]];
	samplelist=Flatten[#,1]&@sampledata[[All,2]];
	samplebond=Flatten[#,1]&@sampledata[[All,3]];
	sampleindex=Flatten[#,1]&@sampledata[[All,4]];
	bufferlist=Join[bufferlist,samplelist];
	bufferbond=Join[bufferbond,samplebond];
	bufferindex=Join[bufferindex,sampleindex];
	bufferens=Join[bufferens,sampleens];
	Print["Length of Samples: ",Length@sampleens+10];
	
	pre=predictEnBatch[\[Mu],\[Sigma],bufferbond,bufferindex,energynets,tgpu];
	un=Variance@pre;
	mpre=Mean@pre;
	Print["Buffer Energy Min: ",Min@mpre];
	Print["Buffer Min Index: ",Ordering[mpre,addsamples]];
	
	Do[
		index=Union@Join[Ordering[un,-j],Ordering[mpre,j]];
		index=Complement[index,buffer];
		
		fea=predictFea[bufferbond[[index]],bufferindex[[index]],featurenet,tgpu];
		reducefea=DimensionReduce[fea,2,Method->"TSNE"];
		clusters=ClusteringComponents[reducefea,addsamples,1,Method->"KMeans"];
		sortlabel=Thread[{clusters,index,un[[index]],mpre[[index]]}];
		newindex=MinimalBy[#,Last,1]&/@Gather[
			sortlabel,
			First[#1]==First[#2]&
		]//Flatten[#,1]&//Part[#,All,2]&;
		
		If[Length@newindex==addsamples,
			Break[]
		],
		{j,Round[.1*Length@mpre],Length@mpre,100}
	];
	Export[dir2<>"/save/reducefea/"<>ToString[i]<>".txt",reducefea,"Table"];
	Export[dir2<>"/save/sortlabel/"<>ToString[i]<>".txt",sortlabel,"Table"];
	
	DeleteFile[FileNames[All,dir2<>"/buffer/new",{2}]];
	DeleteFile[FileNames[All,dir2<>"/buffer/energy"]];
	newlist=bufferlist[[newindex]];
	newcoor=pos2coor[newlist,sort,inicoor];
	Do[
		MapIndexed[
			(posdir=dir2<>"/buffer/new/"<>StringPadLeft[ToString@(#2[[1]]+addsamples*(j-1)),2,"0"];
			Export[posdir<>"/POSCAR",StringJoin[poscarhead,"\n",TextString@TableForm@#],"Text"])&,
			newcoor
		],
		{j,2}
	];
	
	subjobs[i,dir2,machine,number,gpus];
	newefile=StringSplit[Import[#,"Text"]][[-8]]&/@FileNames[All,dir2<>"/buffer/energy"];
	newens=StringCases[newefile,a__~~"E"~~b__:>ToExpression[a]*10^ToExpression[b]];
	{newens1,newens2}=Partition[newens,addsamples];
	newens1=If[Length@#==1,#,1]&/@newens1//Flatten;
	newens2=If[Length@#==1,#,-1]&/@newens2//Flatten;
	newens1=If[NumberQ@#,#,1]&/@newens1;
	newens2=If[NumberQ@#,#,-1]&/@newens2;
	vasp=Flatten@Position[If[#<.1,1,0]&/@Abs[newens1-newens2],1];
	newindex=newindex[[vasp]];
	newens=newens1[[vasp]];
	bufferens=ReplacePart[bufferens,Thread[newindex->newens]];
	buffer=Join[buffer,newindex];
	Print[StringTemplate["\nLength of Buffer: ``"][Length@buffer]];
	Print["Uncertainty: "<>ToString@un[[newindex]]];
	Print["Predict Energy: "<>ToString@mpre[[newindex]]];
	Print["New Add Index: "<>ToString@newindex];
	Print["VASP Energy1: "<>ToString@newens1];
	Print["VASP Energy2: "<>ToString@newens2];
	Print["New Add "<>ToString@Length@newens<>" Energy: "<>ToString@newens];
	MapIndexed[
		Export[dir2<>"/save/roundsample/"<>ToString[i]<>"/POSCAR"<>StringPadLeft[ToString@#2[[1]],2,"0"],
			StringJoin[poscarhead,"\n",TextString@TableForm@#1],
			"Text"
		]&,
		newcoor[[vasp]]
	];
	Export[dir2<>"/save/roundenergy/DFT_"<>ToString[i]<>".txt",newens,"Table"];
	Export[dir2<>"/save/roundenergy/Network_"<>ToString[i]<>".txt",mpre[[newindex]],"Table"];
	Export[dir2<>"/save/roundbond/Bond_"<>ToString[i]<>".mtx.gz",Flatten/@bufferbond[[newindex]]];
	Export[dir2<>"/save/roundindex/Index_"<>ToString[i]<>".mtx.gz",Flatten/@bufferindex[[newindex]]];
	
	trainbond=bufferbond[[buffer]];
	trainindex=bufferindex[[buffer]];
	trainens=bufferens[[buffer]];
	trainlist=bufferlist[[buffer]];
	\[Mu]=trainens//Mean;
	\[Sigma]=trainens//StandardDeviation;
	trainens=(trainens-\[Mu])/\[Sigma];
	valens=(dataens[[151;;300]]-\[Mu])/\[Sigma];
	
	minindex=Ordering[trainens,1][[1]];
	inibondfea=trainbond[[minindex]];
	ininear=ArrayReshape[#,{72,12}]&@Flatten@trainindex[[minindex]];
	iniposlist=trainlist[[minindex]];
	min=bufferens[[buffer]][[minindex]];
	Print["Round Energy: ",min];
	Internal`StuffBag[recordmin,min],
	{i,trainrounds}
];
Export
Networks
untrained=NetInitialize[wcgnet,Method->{"Xavier","Distribution"->"Uniform"}];
Export[dir2<>"/save/networks/"<>StringTake[alloy,2;;-1]<>"_wcgcnn_ac_predict_untrained.wlnet",untrained];
Export[dir2<>"/save/networks/"<>StringTake[alloy,2;;-1]<>"_wcgcnn_ac_predict.wlnet",bestnets[[1]]];
Export[dir2<>"/save/networks/"<>StringTake[alloy,2;;-1]<>"_wcgcnn_ac_agent.wlnet",agent];
Round Energy
Export[dir2<>"/save/conformers/energy.txt",Internal`BagPart[recordmin,All]];
Round Parameters
Export[dir2<>"/save/parameters/poslist.txt",iniposlist];
Export[dir2<>"/save/parameters/ininear.txt",ininear];
Export[dir2<>"/save/parameters/inibondfea.txt",inibondfea];
Export[dir2<>"/save/parameters/mu.txt",Internal`BagPart[recordmu,All]];
Export[dir2<>"/save/parameters/sigma.txt",Internal`BagPart[recordsigma,All]];
Buffer Samples
Export[dir2<>"/save/conformers/buffer_Energy.dat",bufferens,"Real64"];
Export[dir2<>"/save/conformers/buffer_Uncertainty.txt",un];
Export[dir2<>"/save/conformers/buffer_NearIndex.mtx.gz",Flatten/@bufferindex];
Export[dir2<>"/save/conformers/buffer_BondFea.mtx.gz",Flatten/@bufferbond];